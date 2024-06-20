/***********************************************************
 * A Cuda translation of Aaron's C implementation          *
 *   of Flash Attention; Date: June 2024                   *
 ***********************************************************/

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>
#include <sys/time.h>

#define GPU_RUNS 50

__host__ int gpuAssert(cudaError_t code) {
  if(code != cudaSuccess) {
    printf("GPU Error: %s\n", cudaGetErrorString(code));
    return -1;
  }
  return 0;
}


__device__ __forceinline__ float atomicMaxFloat (float * addr, float value) {
    float old;
    old = (value >= 0) ? __int_as_float(atomicMax((int *)addr, __float_as_int(value))) :
         __uint_as_float(atomicMin((unsigned int *)addr, __float_as_uint(value)));

    return old;
}

template <const int BN, const int TN, const int mul>
__global__ void __launch_bounds__((BN * BN) / (TN * TN), 1)
s2mm_kernel(int N, int d, const float* Q, const float* K, const float* V, float* O, float* ms) {

  const int num_block_out = BN * BN;
  const int num_thread_out = TN * TN;
  const int num_threads = num_block_out / num_thread_out;
  assert(num_threads == blockDim.x);

  // Shared memory
  extern __shared__ float shared_memory[];
  float* shared_Q = shared_memory;
  float* shared_K = shared_memory + BN * BN * mul;
  float* shared_P = shared_K + BN * (BN+1);
  float* shared_V = shared_K;

  float* maxs = shared_P + BN * BN;   // [BN]
  float* sums = maxs + BN;            // [BN]
  float* es   = sums + BN;            // [BN]
  float* el   = es   + BN;            // [BN]
  float* li   = el   + BN;            // [BN]
  float* mi   = li   + BN;            // [BN]

  // __shared__ float shared_Q[BN * BN * mul];
  // __shared__ float shared_K[BN * BN];
  // __shared__ float shared_P[BN * BN];

  // Registers
  float reg_O[TN * TN * mul] = {0.0};

  const float* ptr_Q;
  const float* ptr_K;
  const float* ptr_V;
  float* ptr_O;

  const int thread_row_Q = threadIdx.x / BN;
  const int thread_col_Q = threadIdx.x % BN;
  const int stride_Q = num_threads / BN;

//  const int thread_row_K = thread_row_Q;
//  const int thread_col_K = thread_col_Q;
//  const int stride_K = stride_Q;

  const int thread_row_V = thread_row_Q;
  const int thread_col_V = thread_col_Q;
  const int stride_V = stride_Q;

  const int thread_row_out = threadIdx.x / (BN / TN);
  const int thread_col_out = threadIdx.x % (BN / TN);

  const int block_row = blockIdx.x;
  const int num_col_blocks = N / BN;

  // initialize mi, li
  for (int t = threadIdx.x; t < BN; t+=num_threads) {
    mi[t]   = -INFINITY;
    li[t]   = 0;
  }


  ptr_Q = Q + block_row * BN * d;
  float *ptr_shared_Q = shared_Q;
  for (int bidx = 0; bidx < d; bidx += BN) {
    for (int offset = 0; offset < BN; offset += stride_Q) {
      ptr_shared_Q[(thread_row_Q + offset) * BN + thread_col_Q] = ptr_Q[(thread_row_Q + offset) * d + thread_col_Q];
    }
    ptr_Q += BN;
    ptr_shared_Q += BN * BN;
  }

  for (int block_col = 0; block_col < num_col_blocks; ++block_col) {
  
    // initialize maxs, sums
    for (int t = threadIdx.x; t < BN; t+=num_threads) {
      sums[t] = 0;
      maxs[t] = -INFINITY;
    }

    ptr_Q = Q + block_row * BN * d;
    ptr_K = K + block_col * BN;
    // ptr_K = K + block_col * BN * d;
    ptr_V = V + block_col * BN * d;
    ptr_O = O + block_row * BN * d;

    float reg_i[TN] = {0.0};
    float reg_j[TN] = {0.0};
    float reg_P[TN * TN] = {0.0};

    ptr_shared_Q = shared_Q;
    for (int bidx = 0; bidx < d; bidx += BN) {
    
      // This works for input K.T, please FIX ME
#if 0
      for (int offset = 0, offset_global = 0; offset < BN; offset += stride_K, offset_global += stride_Q) {
        shared_K[(thread_row_K + offset) * BN + thread_col_K] = ptr_K[(thread_row_K + offset) * N + thread_col_K];
        // shared_K[(thread_row_K + offset) * BN + thread_col_K] = ptr_K[thread_col_Q * d + thread_row_Q + offset_global];
      }
#else
      { // copies from global to shared memory the slice: 
        // K[block_col*BN : block_col*(BN+1)][bidx : bidx + BN]
        for(int tt = 0; tt < TN*TN; tt ++) {
            int row_idx = tt*stride_Q + thread_row_Q;
            // Kj[q*(d+1) + r] = K[glb_ind];
            shared_K[row_idx*(BN+1) + thread_col_Q] = ptr_K[row_idx*N + thread_col_Q];
        }
      }
#endif
      __syncthreads();

      ptr_K += BN;

      for (int idx = 0; idx < BN; ++idx) {

#if 1
        for (int i = 0; i < TN; ++i) {
          reg_i[i] = ptr_shared_Q[(thread_row_out * TN + i) * BN + idx];
        }
        for (int i = 0; i < TN; ++i) {
          //reg_j[i] = shared_K[idx * BN + thread_col_out * TN + i];
          reg_j[i] = shared_K[(thread_col_out * TN + i) * (BN+1) + idx];
        }
        for (int i = 0; i < TN; ++i) {
          for (int j = 0; j < TN; ++j) {
            reg_P[i * TN + j] += reg_i[i] * reg_j[j];
          }
        }
#else
        for (int i = 0; i < TN; ++i) {
          for (int j = 0; j < TN; ++j) {
            reg_P[i * TN + j] += ptr_shared_Q[(thread_row_out * TN + i) * BN + idx] * 
                                 shared_K[(thread_col_out * TN + j) * (BN+1) + idx] ;
          }
        }
#endif
      }

      ptr_shared_Q += BN * BN;
      __syncthreads();
    }

    ///////////////////////////////////
    // reductions of softmax layer
    ///////////////////////////////////

    for (int i = 0; i < TN; i++) {
      float loc_max = reg_P[i * TN + 0];
      for (int j = 1; j < TN; j++) {
        //atomicMaxFloat(&maxs[thread_row_out*TN + i], reg_P[i * TN + j]);
        if (loc_max < reg_P[i * TN + j])
            loc_max = reg_P[i * TN + j];
        //loc_max = max(loc_max, reg_P[i * TN + j]);
      }
      const int ii = thread_row_out*TN + i;
      atomicMaxFloat(&maxs[ii], loc_max);
    }
    __syncthreads();

    #pragma unroll
    for (int i = 0; i < TN; i++) {
      const int ii = thread_row_out*TN + i;
      float row_max = maxs[ii];
      float loc_sum = 0;
      #pragma unroll
      for (int j = 0; j < TN; j++) {
        float pij = reg_P[i * TN + j];
        pij = exp( pij - row_max );
        loc_sum += pij;
        reg_P[i * TN + j] = pij;
      }
      //atomicAdd(&sums[ii], loc_sum); // this is very expensive for some reason; hence we serialize it
      shared_P[thread_col_out*BN + ii] = loc_sum;
    }
    __syncthreads();

    for(int t=threadIdx.x; t < BN; t+=num_threads) {
        float fin_sum = 0;
        #pragma unroll
        for(int j=0; j<BN/TN; j++) {
            fin_sum += shared_P[j*BN + t];
        }
        sums[t] = fin_sum;
    }
    __syncthreads();

    if(threadIdx.x < BN) { // must hold: BN >= TN*TN
      const int ii = threadIdx.x;
      float mi_old = mi[ii];
      float mx = maxs[ii];
      float mi_new = (mi_old > mx) ? mi_old : mx;
      float eij = exp(mx - mi_new);
      float eli = li[ii] * exp(mi_old - mi_new);
      float li_new = eli + sums[ii] * eij;

      mi[ii] = mi_new;
      li[ii] = li_new;
      es[ii] = eij;
      el[ii] = eli;
    }
    __syncthreads();

    //Pij[ii*Bc+jj] = es[ii]*pij;
    for (int i = 0; i < TN; i++) {
      int ii = thread_row_out*TN + i;
      for (int j = 0; j < TN; j++) {
        float pij = reg_P[i * TN + j];
        reg_P[i * TN + j] = es[ii]*pij;
      }
    }

    ///////////////////////////////////
    // end reductions of softmax layer
    ///////////////////////////////////


    for (int i = 0; i < TN; ++i) {
      for (int j = 0; j < TN; ++j) {
        shared_P[(thread_row_out * TN + i) * BN + thread_col_out * TN + j] = reg_P[i * TN + j];
      }
    }

    // here insert the softmax layer

    float* ptr_reg_O = reg_O;
    for (int k = 0; k < mul; k++) {
      for (int offset = 0; offset < BN; offset += stride_V) {
        shared_V[(thread_row_V + offset) * BN + thread_col_V] = ptr_V[(thread_row_V + offset) * d + thread_col_V];
      }
      __syncthreads();

      ptr_V += BN;

      int row_offset = thread_row_out * TN;

      // ptr_reg_O *= el[ii];
      for (int i = 0; i < TN; i++) {
        int ii = row_offset + i;
        for (int j = 0; j < TN; j++) {
            ptr_reg_O[i * TN + j] *= el[ii];
        }
      }

      // calculate per-thread results
      for (int idx = 0; idx < BN; ++idx) {
#if 1
        // block into registers
        for (int i = 0; i < TN; ++i) {
          reg_i[i] = shared_P[(row_offset + i) * BN + idx];
        }
        for (int i = 0; i < TN; ++i) {
          reg_j[i] = shared_V[idx * BN + thread_col_out * TN + i];
        }
        for (int i = 0; i < TN; ++i) {
          for (int j = 0; j < TN; ++j) {
            ptr_reg_O[i * TN + j] += reg_i[i] * reg_j[j];
          }
        }
#else
        for (int i = 0; i < TN; ++i) {
          for (int j = 0; j < TN; ++j) {
            ptr_reg_O[i * TN + j] += shared_P[(row_offset + i) * BN + idx] * //reg_i[i] * 
                                     shared_V[idx * BN + thread_col_out * TN + j]; //reg_j[j];
          }
        }
#endif
      }

      // ptr_reg_O /= li[ii];
      for (int i = 0; i < TN; i++) {
        int ii = row_offset + i;
        for (int j = 0; j < TN; j++) {
            ptr_reg_O[i * TN + j] /= li[ii];
        }
      }

      ptr_reg_O += TN * TN;
      __syncthreads();
    }
    __syncthreads();
  }

  // write out the results
  ptr_O = O + block_row * BN * d;
  float* ptr_reg_O = reg_O;
  for (int bidx = 0; bidx < d; bidx += BN) {
    for (int i = 0; i < TN; ++i) {
      for (int j = 0; j < TN; ++j) {
        ptr_O[(thread_row_out * TN + i) * d + thread_col_out * TN + j] = ptr_reg_O[i * TN + j];
      }
    }
    ptr_O += BN;
    ptr_reg_O += TN * TN;
  }

#if 0
  // For debugging: copy ms back to global memory
  for (int t = threadIdx.x; t < BN; t+=num_threads) {
    int64_t glb_ind = block_row * BN + t;
    ms[glb_ind] = mi[t];
  }
#endif

}

////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////

__host__ float
L2(float *x, size_t c)
{
        float sum;

        sum = 0;

        for (size_t i = 0; i < c; i++)
                sum += x[i] * x[i];

        return sqrt(sum);
}

__host__ int
s2mm(float* m_d, float* l_d, float *O_d, float *Q_d, float *K_d, float *V_d, int N, int d)
{
    // int Br, Bc, Tr, Tc;

    // Bc = M / (4 * d);
    // Br = d < Bc ? d : Bc;
    // Tr = N / Br;
    // Tc = N / Bc;

    const int BN = 64; // Br = Bc = Bd = BN
    //const int Bd = BN;
    const int TN = 4;
    const int mul = 2; // d / Bd;

    // // iniatialize m with -INFINITY and l with zero (both have size N)
    // initKer<<<(N+255)/256, 256>>>(m_d, l_d, N);

    // initialize O to zeros
    cudaMemset((void**)&O_d, 0, N*d*sizeof(float));

    // setup execution parameters
    // dim3 block(Bc, Br, 1);
    // dim3 grid (Tr,  1, 1);
    // const size_t shmem_size = (Bc*(d+1) + Br*d + Br*Bc + 5*Br) * sizeof(float);
    dim3 grid(N / BN);
    dim3 block((BN * BN) / (TN * TN));
    const size_t shmem_size = (BN * BN * mul + BN * (BN+1) + BN * BN + 6*BN) * sizeof(float);

    // printf("N %d, d %d, BN %d, Bd %d, TN %d, mul %d, shmem %d\n", N, d, BN, Bd, TN, mul, shmem_size);

    cudaFuncSetAttribute(s2mm_kernel<BN, TN, mul>, cudaFuncAttributeMaxDynamicSharedMemorySize, shmem_size);

    s2mm_kernel<BN, TN, mul><<<grid, block, shmem_size>>>(N, d, Q_d, K_d, V_d, O_d, m_d);
    // cudaDeviceSynchronize();

#if 0
    {
        float* m_h = (float*) malloc(N*sizeof(float));
        cudaMemcpy(m_h, m_d, N*sizeof(float), cudaMemcpyDeviceToHost);
        {
            printf("(N,d,BN,TN)=(%d,%d,%d,%d), ms:\n    ", N,d,BN,TN);
            for(int q=0; q<BN; q++) {
                printf(", %f", m_h[q]);
            }
            printf("\n");
        }

        free(m_h);
    }
#endif

    return 0;
}

int main(int argc, char **argv)
{
        
    struct timeval ts, te;
    size_t cnt;
    float *Q, *K, *V, *O, dur;
    int N, d;

    if (argc != 3) {
        fprintf(stderr, "Usage:\n");
        fprintf(stderr, "  %s d N Compute with matrices filled with ones\n", argv[0]);
        fprintf(stderr, "  %s N -io  Read matrices from stdin and write O to stdout\n", argv[0]);
        return EXIT_FAILURE;
    }

    bool io_arrays = false;
    // if (argc == 3 && strcmp(argv[2], "-io") == 0) {
    //     io_arrays = true;
    // }

    if (io_arrays) {
        N = atoi(argv[1]);
        scanf("%d %d", &d, &N);
    } else {
        d = atoi(argv[1]);
        N = atoi(argv[2]);
    }

    if (N % d != 0) {
        fprintf(stderr, "d must divide N\n");
        return EXIT_FAILURE;
    }

    cnt = N * d;

    fprintf(stderr, "Initializing data...");

    if ((Q = (float*)calloc(cnt, sizeof(float))) == NULL)
        goto mem_failure;

    if ((K = (float*)calloc(cnt, sizeof(float))) == NULL)
        goto mem_failure;

    if ((V = (float*)calloc(cnt, sizeof(float))) == NULL)
        goto mem_failure;

    if ((O = (float*)calloc(cnt, sizeof(float))) == NULL)
        goto mem_failure;

    if (io_arrays) {
        for (int i = 0; i < d * N; i++) scanf("%f", &Q[i]);
        for (int i = 0; i < d * N; i++) scanf("%f", &K[i]);
        for (int i = 0; i < d * N; i++) scanf("%f", &V[i]);
    } else {
        for (size_t i = 0; i < cnt; i++) {
            Q[i] = K[i] = V[i] = 1;
        }
    }

    fprintf(stderr, "done.\n");

    {
        float *Q_d, *K_d, *V_d, *O_d, *m_d, *l_d;

        cudaSetDevice(1);

        // allocate memory on device
        cudaMalloc((void**) &Q_d, cnt*sizeof(float));
        cudaMalloc((void**) &O_d, cnt*sizeof(float));
        cudaMalloc((void**) &V_d, cnt*sizeof(float));
        cudaMalloc((void**) &K_d, cnt*sizeof(float));
        cudaMalloc((void**) &m_d, N*sizeof(float));
        cudaMalloc((void**) &l_d, N*sizeof(float));

        // copy host memory to device
        cudaMemcpy(Q_d, Q, cnt*sizeof(float), cudaMemcpyHostToDevice);
        cudaMemcpy(V_d, V, cnt*sizeof(float), cudaMemcpyHostToDevice);
        cudaMemcpy(K_d, K, cnt*sizeof(float), cudaMemcpyHostToDevice);

        fprintf(stderr, "Warming up...");

        s2mm(m_d, l_d, O_d, Q_d, K_d, V_d, N, d);
        cudaDeviceSynchronize();
        gpuAssert( cudaPeekAtLastError() );

        fprintf(stderr, "done.\n");
        fprintf(stderr, "Running s2mm...");

        gettimeofday(&ts, NULL);

        for(int i=0; i<GPU_RUNS; i++) {
            s2mm(m_d, l_d, O_d, Q_d, K_d, V_d, N, d);
        }
        cudaDeviceSynchronize();
        gpuAssert( cudaPeekAtLastError() );

        gettimeofday(&te, NULL);

        fprintf(stderr, "done.\n");

        dur = (double)(te.tv_usec - ts.tv_usec) / 1e6 +
                          (double)(te.tv_sec - ts.tv_sec);
        dur = dur / GPU_RUNS;

        cudaMemcpy(O, O_d, cnt*sizeof(float), cudaMemcpyDeviceToHost);
        cudaDeviceSynchronize();

        if (io_arrays) {
            for (int i = 0; i < N; i++) {
                for (int j = 0; j < d; j++) {
                    if (j > 0) putchar(' ');
                    printf("%f", O[d * i + j]);
                }
                putchar('\n');
            }
        } else {
            // output should be matrix with all elements set to cnt (N * d)
            fprintf(stderr, "L2 norm is %lf (should be %lf)\n", L2(O, cnt), sqrt(cnt));
        }

        /* QK^t is 2N^2d flops, so is PV. softmax(S) (row-wise)
         * exp(S[i]) / sum_j exp(P[i, j] - max(P[i]))
         * is N * (N + 4N) = 5 N^2 flops, but exp is more expensive. */
        fprintf(stderr,
                "Compute rate: %lf Gflops/s, runtime: %lf\n",
                4.0 * d * N * N / dur / 1e9,  dur*1e6);

        cudaFree(Q_d);
        cudaFree(K_d);
        cudaFree(V_d);
        cudaFree(O_d);
        cudaFree(m_d);
        cudaFree(l_d);
    }

    free(Q);
    free(K);
    free(V);
    free(O);

    return EXIT_SUCCESS;

mem_failure:
        printf("Failed to allocate memory.\n");
        return EXIT_FAILURE;
}
