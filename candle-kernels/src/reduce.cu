#include "cuda_utils.cuh"
#include <cmath>
#include <stdint.h>

#define WARP_SIZE 32
const int BLOCK_SIZE = 1024;

static __device__ __forceinline__ float warp_reduce_max(float x) {
#pragma unroll
    for (int offset = 16; offset > 0; offset >>= 1) {
        x = fmaxf(x, __shfl_xor_sync(0xffffffff, x, offset, 32));
    }
    return x;
}

// TODO: Maybe add some fast_sum_f16_f32 variant that not only accumulate in f32
// but also expect a f32 output so that this can be used for normalization e.g.
// in softmax.

// Fast reduce sum kernel, this assumes that the dimensions to loop over are at
// the end, each block is responsible for populating one value in the output
// array. There are at most 1024 threads per block.
template <typename T>
__device__ void
fast_sum(const size_t src_numel, const size_t el_to_sum_per_block,
         const size_t num_dims, const size_t *info, const T *src, T *dst) {
  const size_t *dims = info;
  const size_t *strides = info + num_dims;

  __shared__ T shr[BLOCK_SIZE];
  size_t tid = threadIdx.x;
  size_t dst_id = blockIdx.x;

  shr[tid] = 0;
  // Elements summed in this block range from dst_id * el_to_sum_per_block
  // to (dst_id + 1) * el_to_sum_per_block.
  size_t start_idx = dst_id * el_to_sum_per_block;
  size_t stop_idx = min(start_idx + el_to_sum_per_block, src_numel);
  size_t idx = start_idx + tid;

  while (idx < stop_idx) {
    // TODO: Fast version for the contiguous case.
    size_t strided_i = get_strided_index(idx, num_dims, dims, strides);
    shr[tid] += src[strided_i];
    idx += blockDim.x;
  }

  // Parallel reduction, see the slides:
  // https://www.olcf.ornl.gov/wp-content/uploads/2019/12/05_Atomics_Reductions_Warp_Shuffle.pdf
  // https://stackoverflow.com/questions/66078814/is-cuda-atomicadd-operation-faster-than-launch-another-kernel-when-we-do-reduce
  for (int s = blockDim.x / 2; s > 0; s >>= 1) {
    __syncthreads();
    if (tid < s)
      shr[tid] += shr[tid + s];
  }

  if (tid == 0)
    dst[dst_id] = shr[0];
}

static __device__ __forceinline__ float2 warp_reduce_sum(float2 a) {
#pragma unroll
    for (int mask = 16; mask > 0; mask >>= 1) {
        a.x += __shfl_xor_sync(0xffffffff, a.x, mask, 32);
        a.y += __shfl_xor_sync(0xffffffff, a.y, mask, 32);
    }
    return a;
}

static __device__ __forceinline__ float warp_reduce_sum(float x) {
#pragma unroll
    for (int mask = 16; mask > 0; mask >>= 1) {
        x += __shfl_xor_sync(0xffffffff, x, mask, 32);
    }
    return x;
}

// LayerNorm implementation adapted from ggml, accumulation is made using f32.
// https://github.com/ggerganov/llama.cpp/blob/d59bd97065cd7ded6c4ecab54b1d5e0b1b11e318/ggml-cuda.cu#L477
template <typename T>
__device__ void layernorm(const T * x, T * dst, const T * alpha, const T * beta, const int ncols, const int block_size, const float eps) {
    const int row = blockIdx.x*blockDim.y + threadIdx.y;
    const int tid = threadIdx.x;

    float2 mean_var = make_float2(0.f, 0.f);

    for (int col = tid; col < ncols; col += block_size) {
        const float xi = x[row*ncols + col];
        mean_var.x += xi;
        mean_var.y += xi * xi;
    }

    // sum up partial sums
    mean_var = warp_reduce_sum(mean_var);
    if (block_size > WARP_SIZE) {
        __shared__ float2 s_sum[32];
        int warp_id = threadIdx.x / WARP_SIZE;
        int lane_id = threadIdx.x % WARP_SIZE;
        if (lane_id == 0) {
            s_sum[warp_id] = mean_var;
        }
        __syncthreads();
        mean_var = s_sum[lane_id];
        mean_var = warp_reduce_sum(mean_var);
    }

    const float mean = mean_var.x / ncols;
    const float var = mean_var.y / ncols - mean * mean;
    const float inv_std = rsqrtf(var + eps);

    if (alpha == nullptr && beta == nullptr) {
      for (int col = tid; col < ncols; col += block_size) {
          float lhs = (static_cast<float>(x[row*ncols + col]) - mean) * inv_std; 
          dst[row*ncols + col] = static_cast<T>(lhs);
      }
    }
    else if (alpha == nullptr && beta != nullptr) {
      for (int col = tid; col < ncols; col += block_size) {
          float b = static_cast<float>(beta[col]);
          float lhs = (static_cast<float>(x[row*ncols + col]) - mean) * inv_std; 
          dst[row*ncols + col] = static_cast<T>(lhs + b);
      }
    }
    else if (alpha != nullptr && beta == nullptr) {
      for (int col = tid; col < ncols; col += block_size) {
          float a = static_cast<float>(alpha[col]);
          float lhs = (static_cast<float>(x[row*ncols + col]) - mean) * inv_std; 
          dst[row*ncols + col] = static_cast<T>(lhs * a);
      }
    }
    else {
      for (int col = tid; col < ncols; col += block_size) {
          float a = static_cast<float>(alpha[col]);
          float b = static_cast<float>(beta[col]);
          float lhs = (static_cast<float>(x[row*ncols + col]) - mean) * inv_std; 
          dst[row*ncols + col] = static_cast<T>(lhs * a + b);
      }
    }
}

// RmsNorm implementation adapted from ggml, accumulation is made using f32.
// https://github.com/ggerganov/llama.cpp/blob/d59bd97065cd7ded6c4ecab54b1d5e0b1b11e318/ggml-cuda.cu#L523
template <typename T>
__device__ void rmsnorm(const T * x, T * dst, const T * alpha, const int ncols, const int block_size, const float eps) {
    const int row = blockIdx.x*blockDim.y + threadIdx.y;
    const int tid = threadIdx.x;

    float tmp = 0.0f; // partial sum for thread in warp

    for (int col = tid; col < ncols; col += block_size) {
        const float xi = static_cast<float>(x[row*ncols + col]);
        tmp += xi * xi;
    }

    // sum up partial sums
    tmp = warp_reduce_sum(tmp);
    if (block_size > WARP_SIZE) {
        __shared__ float s_sum[32];
        int warp_id = threadIdx.x / WARP_SIZE;
        int lane_id = threadIdx.x % WARP_SIZE;
        if (lane_id == 0) {
            s_sum[warp_id] = tmp;
        }
        __syncthreads();
        tmp = s_sum[lane_id];
        tmp = warp_reduce_sum(tmp);
    }

    const float mean = tmp / ncols;
    const float scale = rsqrtf(mean + eps);

    if (alpha == nullptr) {
      for (int col = tid; col < ncols; col += block_size) {
          dst[row*ncols + col] = static_cast<T>(scale * static_cast<float>(x[row*ncols + col]));
      }
    }
    else {
      for (int col = tid; col < ncols; col += block_size) {
          float a = static_cast<float>(alpha[col]);
          dst[row*ncols + col] = static_cast<T>(scale * static_cast<float>(x[row*ncols + col]) * a);
      }
    }
}

// Softmax implementation adapted from ggml.
// https://github.com/ggerganov/llama.cpp/blob/d59bd97065cd7ded6c4ecab54b1d5e0b1b11e318/ggml-cuda.cu#L4159
template <typename T, typename ACC>
__device__ void softmax(const T * x, T * dst, const int ncols) {
    const int row = blockDim.x*blockIdx.x + threadIdx.x;
    const int block_size = blockDim.y;
    const int tid = threadIdx.y;

    T max_val = -INFINITY;

    for (int col = tid; col < ncols; col += block_size) {
        const int i = row*ncols + col;
        max_val = maxg(max_val, x[i]);
    }

    // find the max value in the block
#pragma unroll
    for (int mask = 16; mask > 0; mask >>= 1) {
        max_val = maxg(max_val, __shfl_xor_sync(0xffffffff, max_val, mask, 32));
    }

    ACC tmp = 0.;

    for (int col = tid; col < ncols; col += block_size) {
        const int i = row*ncols + col;
        const T val = expg(x[i] - max_val);
        tmp += static_cast<ACC>(val);
        dst[i] = val;
    }

    // sum up partial sums
#pragma unroll
    for (int mask = 16; mask > 0; mask >>= 1) {
        tmp += __shfl_xor_sync(0xffffffff, tmp, mask, 32);
    }

    const ACC inv_tmp = 1. / tmp;

    for (int col = tid; col < ncols; col += block_size) {
        const int i = row*ncols + col;
        dst[i] *= inv_tmp;
    }
}

template <typename T>
__device__ void attn_soft_max(const T * x, const T * mask, T * dst, const int ncols, const int nrows_y, const int elem_per_batch, const float scale) {
    const int tid  = threadIdx.x;
    const int rowx = blockIdx.x;
    const int rowy = rowx % nrows_y; // broadcast the mask in the row dimension

    const int block_size = blockDim.x;

    const int warp_id = threadIdx.x / WARP_SIZE;
    const int lane_id = threadIdx.x % WARP_SIZE;

    extern __shared__ float smem[];
    float * buf_iw = smem; // shared memory buffer for inter-warp communication
    // shared memory buffer to cache values between iterations:
    T * vals = dst + (int64_t)rowx*ncols;

    float max_val = -INFINITY;

#pragma unroll
    for (int col0 = 0; col0 < ncols; col0 += block_size) {
        const int col = col0 + tid;

        if (col >= ncols) {
            break;
        }

        const int64_t ix = (int64_t)rowx*ncols + col;

        const int64_t b_idx = elem_per_batch > 0 ? ix / elem_per_batch : 0;
        const int64_t iy = (int64_t)b_idx * (ncols*nrows_y) + rowy*ncols + col;

        const float val = float(x[ix]) * scale + (mask ? float(mask[iy]) : 0.0f);

        vals[col] = val;
        max_val = max(max_val, val);
    }

    // find the max value in the block
    max_val = warp_reduce_max(max_val);
    if (block_size > WARP_SIZE) {
        if (warp_id == 0) {
            buf_iw[lane_id] = -INFINITY;
        }
        __syncthreads();

        if (lane_id == 0) {
            buf_iw[warp_id] = max_val;
        }
        __syncthreads();

        max_val = buf_iw[lane_id];
        max_val = warp_reduce_max(max_val);
    }

    float tmp = 0.0f; // partial sum

#pragma unroll
    for (int col0 = 0; col0 < ncols; col0 += block_size) {
        const int col = col0 + tid;

        if (col >= ncols) {
            break;
        }

        const float val = expf(float(vals[col]) - max_val);
        tmp += val;
        vals[col] = val;
    }

    // find the sum of exps in the block
    tmp = warp_reduce_sum(tmp);
    if (block_size > WARP_SIZE) {
        __syncthreads();
        if (warp_id == 0) {
            buf_iw[lane_id] = 0.0f;
        }
        __syncthreads();

        if (lane_id == 0) {
            buf_iw[warp_id] = tmp;
        }
        __syncthreads();

        tmp = buf_iw[lane_id];
        tmp = warp_reduce_sum(tmp);
    }

    const float inv_sum = 1.0f / tmp;

#pragma unroll
    for (int col0 = 0; col0 < ncols; col0 += block_size) {
        const int col = col0 + tid;

        if (col >= ncols) {
            return;
        }

        const int64_t idst = (int64_t)rowx*ncols + col;
        dst[idst] = float(vals[col]) * inv_sum;
    }
}

template <typename T>
__device__ void ropei(const T * src, const T * cos, const T * sin, T * dst, const uint32_t bh, const uint32_t td) {
    const int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (2 * idx >= bh * td) return;

    uint32_t rope_idx = idx % (td / 2);
    T c = cos[rope_idx];
    T s = sin[rope_idx];

    dst[2 * idx] = src[2 * idx] * c - src[2 * idx + 1] * s;
    dst[2 * idx + 1] = src[2 * idx] * s + src[2 * idx + 1] * c;
}

template <typename T>
__device__ void rope(const T * src, const T * cos, const T * sin, T * dst, const uint32_t bh, const uint32_t td, const uint32_t d) {
    const int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (2 * idx >= bh * td) return;

    uint32_t i_bh = idx / (td / 2);
    uint32_t i_td = idx - (td / 2) * i_bh;
    uint32_t i_t = i_td / (d / 2);
    uint32_t i_d = i_td - (d / 2) * i_t;
    uint32_t i1 = i_bh * td + i_t * d + i_d;
    uint32_t i2 = i1 + d / 2;
    uint32_t i_cs = i_t * (d / 2) + i_d;
    T c = cos[i_cs];
    T s = sin[i_cs];

    dst[i1] = src[i1] * c - src[i2] * s;
    dst[i2] = src[i1] * s + src[i2] * c;
}

template <typename T>
__device__ void rope_thd(
    const T * src,
    const T * cos,
    const T * sin,
    T * dst,
    const uint32_t b,
    const uint32_t t,
    const uint32_t h,
    const uint32_t d
) {
    const int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (2 * idx >= b * t * h * d) return;

    uint32_t i_bth = idx / (d / 2);
    uint32_t i_d = idx - (d / 2) * i_bth;
    uint32_t i_t = (i_bth / h) % t;
    uint32_t i1 = i_bth * d + i_d;
    uint32_t i2 = i1 + d / 2;
    uint32_t i_cs = i_t * (d / 2) + i_d;
    T c = cos[i_cs];
    T s = sin[i_cs];

    dst[i1] = src[i1] * c - src[i2] * s;
    dst[i2] = src[i1] * s + src[i2] * c;
}

template <typename T>
__device__ void
fast_max(const size_t src_numel, const size_t el_to_sum_per_block,
         const size_t num_dims, const size_t *info, const T *src, T *dst) {
  const size_t *dims = info;
  const size_t *strides = info + num_dims;

  __shared__ T shr[BLOCK_SIZE];
  size_t tid = threadIdx.x;
  size_t dst_id = blockIdx.x;

  shr[tid] = -INFINITY;
  // Elements summed in this block range from dst_id * el_to_sum_per_block
  // to (dst_id + 1) * el_to_sum_per_block.
  size_t start_idx = dst_id * el_to_sum_per_block;
  size_t stop_idx = min(start_idx + el_to_sum_per_block, src_numel);
  size_t idx = start_idx + tid;

  while (idx < stop_idx) {
    // TODO: Fast version for the contiguous case.
    size_t strided_i = get_strided_index(idx, num_dims, dims, strides);
    shr[tid] = maxg(shr[tid], src[strided_i]);
    idx += blockDim.x;
  }

  // Parallel reduction, see the slides:
  // https://www.olcf.ornl.gov/wp-content/uploads/2019/12/05_Atomics_Reductions_Warp_Shuffle.pdf
  // https://stackoverflow.com/questions/66078814/is-cuda-atomicadd-operation-faster-than-launch-another-kernel-when-we-do-reduce
  for (int s = blockDim.x / 2; s > 0; s >>= 1) {
    __syncthreads();
    if (tid < s)
      shr[tid] = maxg(shr[tid], shr[tid + s]);
  }

  if (tid == 0)
    dst[dst_id] = shr[0];
}

template <typename T>
__device__ void
fast_min(const size_t src_numel, const size_t el_to_sum_per_block,
         const size_t num_dims, const size_t *info, const T *src, T *dst) {
  const size_t *dims = info;
  const size_t *strides = info + num_dims;

  __shared__ T shr[BLOCK_SIZE];
  size_t tid = threadIdx.x;
  size_t dst_id = blockIdx.x;

  shr[tid] = INFINITY;
  // Elements summed in this block range from dst_id * el_to_sum_per_block
  // to (dst_id + 1) * el_to_sum_per_block.
  size_t start_idx = dst_id * el_to_sum_per_block;
  size_t stop_idx = min(start_idx + el_to_sum_per_block, src_numel);
  size_t idx = start_idx + tid;

  while (idx < stop_idx) {
    // TODO: Fast version for the contiguous case.
    size_t strided_i = get_strided_index(idx, num_dims, dims, strides);
    shr[tid] = ming(shr[tid], src[strided_i]);
    idx += blockDim.x;
  }

  // Parallel reduction, see the slides:
  // https://www.olcf.ornl.gov/wp-content/uploads/2019/12/05_Atomics_Reductions_Warp_Shuffle.pdf
  // https://stackoverflow.com/questions/66078814/is-cuda-atomicadd-operation-faster-than-launch-another-kernel-when-we-do-reduce
  for (int s = blockDim.x / 2; s > 0; s >>= 1) {
    __syncthreads();
    if (tid < s)
      shr[tid] = ming(shr[tid], shr[tid + s]);
  }

  if (tid == 0)
    dst[dst_id] = shr[0];
}

template <typename T>
__device__ void
fast_argmin(const size_t src_numel, const size_t el_to_sum_per_block,
         const size_t num_dims, const size_t *info, const T *src, uint32_t *dst) {
  const size_t *dims = info;
  const size_t *strides = info + num_dims;

  __shared__ T shr[BLOCK_SIZE];
  __shared__ uint32_t shr_index[BLOCK_SIZE];
  size_t tid = threadIdx.x;
  size_t dst_id = blockIdx.x;

  // Not sure how that works on uint32_t and uint8_t but it seems to do ok.
  shr[tid] = INFINITY;
  shr_index[tid] = 0xFFFFFFFF;
  bool not_set = true;
  // Elements summed in this block range from dst_id * el_to_sum_per_block
  // to (dst_id + 1) * el_to_sum_per_block.
  size_t start_idx = dst_id * el_to_sum_per_block;
  size_t stop_idx = min(start_idx + el_to_sum_per_block, src_numel);
  size_t idx = start_idx + tid;

  while (idx < stop_idx) {
    // TODO: Fast version for the contiguous case.
    size_t strided_i = get_strided_index(idx, num_dims, dims, strides);
    if (not_set || src[strided_i] < shr[tid]) {
      shr[tid] = src[strided_i];
      // Assume that the reduction takes place over the last dimension which is contiguous.
      shr_index[tid] = idx % dims[num_dims - 1];
      not_set = false;
    }
    idx += blockDim.x;
  }

  // Parallel reduction, see the slides:
  // https://www.olcf.ornl.gov/wp-content/uploads/2019/12/05_Atomics_Reductions_Warp_Shuffle.pdf
  // https://stackoverflow.com/questions/66078814/is-cuda-atomicadd-operation-faster-than-launch-another-kernel-when-we-do-reduce
  for (int s = blockDim.x / 2; s > 0; s >>= 1) {
    __syncthreads();
    if (tid < s && shr[tid + s] < shr[tid]) {
      shr[tid] = shr[tid + s];
      shr_index[tid] = shr_index[tid + s];
    }
  }

  if (tid == 0)
    dst[dst_id] = shr_index[0];
}

template <typename T>
__device__ void
fast_argmax(const size_t src_numel, const size_t el_to_sum_per_block,
         const size_t num_dims, const size_t *info, const T *src, uint32_t *dst) {
  const size_t *dims = info;
  const size_t *strides = info + num_dims;

  __shared__ T shr[BLOCK_SIZE];
  __shared__ uint32_t shr_index[BLOCK_SIZE];
  size_t tid = threadIdx.x;
  size_t dst_id = blockIdx.x;

  shr[tid] = -INFINITY;
  shr_index[tid] = 0xFFFFFFFF;
  bool not_set = true;
  // Elements summed in this block range from dst_id * el_to_sum_per_block
  // to (dst_id + 1) * el_to_sum_per_block.
  size_t start_idx = dst_id * el_to_sum_per_block;
  size_t stop_idx = min(start_idx + el_to_sum_per_block, src_numel);
  size_t idx = start_idx + tid;

  while (idx < stop_idx) {
    // TODO: Fast version for the contiguous case.
    size_t strided_i = get_strided_index(idx, num_dims, dims, strides);
    if (not_set || src[strided_i] > shr[tid]) {
      shr[tid] = src[strided_i];
      // Assume that the reduction takes place over the last dimension which is contiguous.
      shr_index[tid] = idx % dims[num_dims - 1];
      not_set = false;
    }
    idx += blockDim.x;
  }

  // Parallel reduction, see the slides:
  // https://www.olcf.ornl.gov/wp-content/uploads/2019/12/05_Atomics_Reductions_Warp_Shuffle.pdf
  // https://stackoverflow.com/questions/66078814/is-cuda-atomicadd-operation-faster-than-launch-another-kernel-when-we-do-reduce
  for (int s = blockDim.x / 2; s > 0; s >>= 1) {
    __syncthreads();
    if (tid < s && shr[tid + s] > shr[tid]) {
      shr[tid] = shr[tid + s];
      shr_index[tid] = shr_index[tid + s];
    }
  }

  if (tid == 0)
    dst[dst_id] = shr_index[0];
}

#define FAST_OP(TYPENAME, MIN_NAME, MAX_NAME, ARGMIN_NAME, ARGMAX_NAME, SUM_NAME) \
  extern "C" __global__ void ARGMIN_NAME(                                      \
      const size_t src_numel, const size_t el_to_sum_per_block,                \
      const size_t num_dims, const size_t *info, const TYPENAME *src,          \
      uint32_t *dst) {                                                         \
    fast_argmin(src_numel, el_to_sum_per_block, num_dims, info, src, dst);     \
  }                                                                            \
  extern "C" __global__ void ARGMAX_NAME(                                     \
      const size_t src_numel, const size_t el_to_sum_per_block,                \
      const size_t num_dims, const size_t *info, const TYPENAME *src,          \
      uint32_t *dst) {                                                         \
    fast_argmax(src_numel, el_to_sum_per_block, num_dims, info, src, dst);     \
  }                                                                            \
  extern "C" __global__ void MIN_NAME(                                         \
      const size_t src_numel, const size_t el_to_sum_per_block,                \
      const size_t num_dims, const size_t *info, const TYPENAME *src,          \
      TYPENAME *dst) {                                                         \
    fast_min(src_numel, el_to_sum_per_block, num_dims, info, src, dst);        \
  }                                                                            \
  extern "C" __global__ void MAX_NAME(                                         \
      const size_t src_numel, const size_t el_to_sum_per_block,                \
      const size_t num_dims, const size_t *info, const TYPENAME *src,          \
      TYPENAME *dst) {                                                         \
    fast_max(src_numel, el_to_sum_per_block, num_dims, info, src, dst);        \
  }                                                                            \
  extern "C" __global__ void SUM_NAME(                                         \
      const size_t src_numel, const size_t el_to_sum_per_block,                \
      const size_t num_dims, const size_t *info, const TYPENAME *src,          \
      TYPENAME *dst) {                                                         \
    fast_sum(src_numel, el_to_sum_per_block, num_dims, info, src, dst);        \
  }

#define SUM_OP(TYPENAME, FN_NAME)                                              \
  extern "C" __global__ void FN_NAME(                                          \
      const size_t numel, const size_t num_dims, const size_t num_sum_dims,    \
      const size_t *info, const TYPENAME *inp, TYPENAME *out) {                \
    const size_t *dims = info;                                                 \
    const size_t *strides = info + num_dims;                                   \
    const size_t *sum_dims_l = info + 2 * num_dims;                            \
    const size_t *sum_dims_s = info + 2 * num_dims + num_sum_dims;             \
    if (is_contiguous(num_dims, dims, strides)) {                              \
      for (unsigned int i = blockIdx.x * blockDim.x + threadIdx.x; i < numel;  \
           i += blockDim.x * gridDim.x) {                                      \
        size_t dst_index = i;                                                  \
        for (unsigned int nd = 0; nd < num_sum_dims; ++nd) {                   \
          size_t stride = sum_dims_s[nd];                                      \
          size_t pre = dst_index / stride;                                     \
          size_t post = dst_index % stride;                                    \
          dst_index = (pre / sum_dims_l[nd]) * stride + post;                  \
        }                                                                      \
        atomicAdd(out + dst_index, inp[i]);                                    \
      }                                                                        \
    } else {                                                                   \
      for (unsigned int i = blockIdx.x * blockDim.x + threadIdx.x; i < numel;  \
           i += blockDim.x * gridDim.x) {                                      \
        unsigned strided_i = get_strided_index(i, num_dims, dims, strides);    \
        size_t dst_index = i;                                                  \
        for (unsigned int nd = 0; nd < num_sum_dims; ++nd) {                   \
          size_t stride = sum_dims_s[nd];                                      \
          size_t pre = dst_index / stride;                                     \
          size_t post = dst_index % stride;                                    \
          dst_index = (pre / sum_dims_l[nd]) * stride + post;                  \
        }                                                                      \
        atomicAdd(out + dst_index, inp[strided_i]);                            \
      }                                                                        \
    }                                                                          \
  }

#define SOFTMAX_OP(TYPENAME, ACC_TYPENAME, FN_NAME) \
  extern "C" __global__ void FN_NAME(                                          \
      const TYPENAME *src, TYPENAME *dst,                                      \
      const int n_cols) {                                                      \
    softmax<TYPENAME, ACC_TYPENAME>(src, dst, n_cols);                         \
  }     

#define ATTN_SOFTMAX_OP(TYPENAME, FN_NAME) \
  extern "C" __global__ void FN_NAME(                                          \
      const TYPENAME * x,                                                      \
      const TYPENAME * mask,                                                   \
      TYPENAME * dst,                                                          \
      const int ncols,                                                         \
      const int nrows_y,                                                       \
      const int elem_per_batch,                                                       \
      const float scale                                                       \
  ) {                                                                          \
    attn_soft_max<TYPENAME>(x, mask, dst, ncols, nrows_y, elem_per_batch, scale);               \
  }                                                                                \

#define RMSNORM_OP(TYPENAME, FN_NAME) \
  extern "C" __global__ void FN_NAME(                                          \
      const TYPENAME *src, TYPENAME *dst, const TYPENAME *alpha,               \
      const int n_cols, const int block_size, const float eps) {               \
    rmsnorm<TYPENAME>(src, dst, alpha, n_cols, block_size, eps);               \
  }                                                                            \

#define LAYERNORM_OP(TYPENAME, FN_NAME) \
  extern "C" __global__ void FN_NAME(                                          \
      const TYPENAME *src, TYPENAME *dst, const TYPENAME *alpha,               \
      const TYPENAME *beta, const int n_cols, const int block_size, const float eps) { \
    layernorm<TYPENAME>(src, dst, alpha, beta, n_cols, block_size, eps);       \
  }                                                                            \

#define ROPE_OP(TYPENAME, FN_NAME, FN_NAME_I, FN_NAME_THD) \
  extern "C" __global__ void FN_NAME_I( \
      const TYPENAME *src, \
      const TYPENAME *cos, \
      const TYPENAME *sin, \
      TYPENAME *dst, \
      const uint32_t bh, \
      const uint32_t td) { \
    ropei<TYPENAME>(src, cos, sin, dst, bh, td); \
  } \
  extern "C" __global__ void FN_NAME( \
      const TYPENAME *src, \
      const TYPENAME *cos, \
      const TYPENAME *sin, \
      TYPENAME *dst, \
      const uint32_t bh, \
      const uint32_t td, \
      const uint32_t d) { \
    rope<TYPENAME>(src, cos, sin, dst, bh, td, d); \
  } \
  extern "C" __global__ void FN_NAME_THD( \
      const TYPENAME *src, \
      const TYPENAME *cos, \
      const TYPENAME *sin, \
      TYPENAME *dst, \
      const uint32_t b, \
      const uint32_t t, \
      const uint32_t h, \
      const uint32_t d) { \
    rope_thd<TYPENAME>(src, cos, sin, dst, b, t, h, d); \
  } \

#if __CUDA_ARCH__ >= 800
#include "cuda_bf16.h"
SOFTMAX_OP(__nv_bfloat16, float, softmax_bf16)
ATTN_SOFTMAX_OP(__nv_bfloat16, attn_soft_max_bf16)
RMSNORM_OP(__nv_bfloat16, rmsnorm_bf16)
LAYERNORM_OP(__nv_bfloat16, layernorm_bf16)
ROPE_OP(__nv_bfloat16, rope_bf16, rope_i_bf16, rope_thd_bf16)
SUM_OP(__nv_bfloat16, sum_bf16)
FAST_OP(__nv_bfloat16, fast_min_bf16, fast_max_bf16, fast_argmin_bf16, fast_argmax_bf16, fast_sum_bf16)

// NOTE: No reduce ops for f8
// SUM_OP(__nv_fp8_e4m3, sum_fp8_e4m3)
// SOFTMAX_OP(__nv_fp8_e4m3, float, softmax_fp8_e4m3)
// RMSNORM_OP(__nv_fp8_e4m3, rmsnorm_fp8_e4m3)
// LAYERNORM_OP(__nv_fp8_e4m3, layernorm_fp8_e4m3)
// ROPE_OP(__nv_fp8_e4m3, rope_fp8_e4m3, rope_i_fp8_e4m3, rope_thd_fp8_e4m3)
// FAST_OP(__nv_fp8_e4m3, fast_min_fp8_e4m3, fast_max_fp8_e4m3, fast_argmin_fp8_e4m3, fast_argmax_fp8_e4m3, fast_sum_fp8_e4m3)
#endif

#if __CUDA_ARCH__ >= 530
SOFTMAX_OP(__half, float, softmax_f16)
ATTN_SOFTMAX_OP(__half, attn_soft_max_f16)
RMSNORM_OP(__half, rmsnorm_f16)
LAYERNORM_OP(__half, layernorm_f16)
ROPE_OP(__half, rope_f16, rope_i_f16, rope_thd_f16)
SUM_OP(__half, sum_f16)
FAST_OP(__half, fast_min_f16, fast_max_f16, fast_argmin_f16, fast_argmax_f16, fast_sum_f16)
#endif

SUM_OP(float, sum_f32)
SUM_OP(double, sum_f64)
SUM_OP(uint32_t, sum_u32)
SOFTMAX_OP(float, float, softmax_f32)
SOFTMAX_OP(double, double, softmax_f64)
ATTN_SOFTMAX_OP(float, attn_soft_max_f32)
ATTN_SOFTMAX_OP(double, attn_soft_max_f64)
RMSNORM_OP(float, rmsnorm_f32)
RMSNORM_OP(double, rmsnorm_f64)
LAYERNORM_OP(float, layernorm_f32)
LAYERNORM_OP(double, layernorm_f64)
ROPE_OP(float, rope_f32, rope_i_f32, rope_thd_f32)
ROPE_OP(double, rope_f64, rope_i_f64, rope_thd_f64)

FAST_OP(float, fast_min_f32, fast_max_f32, fast_argmin_f32, fast_argmax_f32, fast_sum_f32)
FAST_OP(double, fast_min_f64, fast_max_f64, fast_argmin_f64, fast_argmax_f64, fast_sum_f64)
FAST_OP(uint32_t, fast_min_u32, fast_max_u32, fast_argmin_u32, fast_argmax_u32, fast_sum_u32)
FAST_OP(int16_t, fast_min_i16, fast_max_i16, fast_argmin_i16, fast_argmax_i16, fast_sum_i16)
FAST_OP(int32_t, fast_min_i32, fast_max_i32, fast_argmin_i32, fast_argmax_i32, fast_sum_i32)
FAST_OP(int64_t, fast_min_i64, fast_max_i64, fast_argmin_i64, fast_argmax_i64, fast_sum_i64)
FAST_OP(uint8_t, fast_min_u8, fast_max_u8, fast_argmin_u8, fast_argmax_u8, fast_sum_u8)
