/*
 * Copyright (c) 2021-2022, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#pragma once

#include "reachability_faiss.cuh"

#include <raft/util/cuda_utils.cuh>
#include <raft/util/cudart_utils.hpp>

#include <raft/linalg/unary_op.cuh>

#include <raft/sparse/convert/csr.cuh>
#include <raft/sparse/linalg/symmetrize.cuh>

#include <rmm/device_uvector.hpp>
#include <rmm/exec_policy.hpp>

#include <cuml/neighbors/knn.hpp>
#include <raft/distance/distance.cuh>

#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/zip_iterator.h>
#include <thrust/transform.h>
#include <thrust/tuple.h>

#include <chrono>

#define CHECK_CUDA_ERROR(val) check((val), #val, __FILE__, __LINE__)
template <typename T>
void check(T err, const char* const func, const char* const file,
           const int line)
{
    if (err != cudaSuccess)
    {
        std::cerr << "CUDA Runtime Error at: " << file << ":" << line
                  << std::endl;
        std::cerr << cudaGetErrorString(err) << " " << func << std::endl;
        // We don't exit when we encounter CUDA errors in this example.
        // std::exit(EXIT_FAILURE);
    }
}

#define CHECK_LAST_CUDA_ERROR() checkLast(__FILE__, __LINE__)
void checkLast(const char* const file, const int line)
{
    cudaError_t err{cudaGetLastError()};
    if (err != cudaSuccess)
    {
        std::cerr << "CUDA Runtime Error at: " << file << ":" << line
                  << std::endl;
        std::cerr << cudaGetErrorString(err) << std::endl;
        // We don't exit when we encounter CUDA errors in this example.
        // std::exit(EXIT_FAILURE);
    }
}


namespace ML {
namespace HDBSCAN {
namespace detail {
namespace Reachability {

/**
 * Extract core distances from KNN graph. This is essentially
 * performing a knn_dists[:,min_pts]
 * @tparam value_idx data type for integrals
 * @tparam value_t data type for distance
 * @tparam tpb block size for kernel
 * @param[in] knn_dists knn distance array (size n * k)
 * @param[in] min_samples this neighbor will be selected for core distances
 * @param[in] n_neighbors the number of neighbors of each point in the knn graph
 * @param[in] n number of samples
 * @param[out] out output array (size n)
 * @param[in] stream stream for which to order cuda operations
 */
template <typename value_idx, typename value_t, int tpb = 256>
void core_distances(
  value_t* knn_dists, int min_samples, int n_neighbors, size_t n, value_t* out, cudaStream_t stream)
{
  ASSERT(n_neighbors >= min_samples,
         "the size of the neighborhood should be greater than or equal to min_samples");

  int blocks = raft::ceildiv(n, (size_t)tpb);

  auto exec_policy = rmm::exec_policy(stream);

  auto indices = thrust::make_counting_iterator<value_idx>(0);

  thrust::transform(exec_policy, indices, indices + n, out, [=] __device__(value_idx row) {
    return knn_dists[row * n_neighbors + (min_samples - 1)];
  });
}

/**
 * Wraps the brute force knn API, to be used for both training and prediction
 * @tparam value_idx data type for integrals
 * @tparam value_t data type for distance
 * @param[in] handle raft handle for resource reuse
 * @param[in] X input data points (size m * n)
 * @param[out] inds nearest neighbor indices (size n_search_items * k)
 * @param[out] dists nearest neighbor distances (size n_search_items * k)
 * @param[in] m number of rows in X
 * @param[in] n number of columns in X
 * @param[in] search_items array of items to search of dimensionality D (size n_search_items * n)
 * @param[in] n_search_items number of rows in search_items
 * @param[in] k number of nearest neighbors
 * @param[in] metric distance metric to use
 */
template <typename value_idx, typename value_t>
void compute_knn(const raft::handle_t& handle,
                 const value_t* X,
                 value_idx* inds,
                 value_t* dists,
                 size_t m,
                 size_t n,
                 const value_t* search_items,
                 size_t n_search_items,
                 int k,
                 raft::distance::DistanceType metric)
{
  auto stream      = handle.get_stream();
  auto exec_policy = handle.get_thrust_policy();
  std::vector<value_t*> inputs;
  inputs.push_back(const_cast<value_t*>(X));

  std::vector<int> sizes;
  sizes.push_back(m);

  // This is temporary. Once faiss is updated, we should be able to
  // pass value_idx through to knn.
  rmm::device_uvector<int64_t> int64_indices(k * n_search_items, stream);

  // perform knn
  brute_force_knn(handle,
                  inputs,
                  sizes,
                  n,
                  const_cast<value_t*>(search_items),
                  n_search_items,
                  int64_indices.data(),
                  dists,
                  k,
                  true,
                  true,
                  metric);

  // convert from current knn's 64-bit to 32-bit.
  thrust::transform(exec_policy,
                    int64_indices.data(),
                    int64_indices.data() + int64_indices.size(),
                    inds,
                    [] __device__(int64_t in) -> value_idx { return in; });
}


template <typename value_idx, typename value_t>
void compute_knn_GF(const raft::handle_t& handle,
                 const value_t* X1,
                  const value_t* X2,
                 value_idx* inds,
                 value_t* dists,
                 size_t m,
                 size_t n1,
                size_t n2,
                 const value_t* search_items1,
                 const value_t* search_items2,
                 size_t n_search_items,
                 int k,
                 raft::distance::DistanceType metric)
{
  auto stream      = handle.get_stream();
  auto exec_policy = handle.get_thrust_policy();
  //size_t ps =2;
  //auto ps = pool.get_pool_size();
  //std::cout <<"Pool size: " <<  ps << std::endl;
  std::vector<value_t*> inputs1, inputs2;
  //size_t per_thread  = m / (ps);

   std::vector<std::vector<value_t*>> inputs1_vec;
   std::vector<std::vector<value_t*>> inputs2_vec;


  std::vector<int> sizes;

  

  // for (size_t i = 0; i < ps; i++) {
  //   inputs1.push_back(const_cast<value_t*>(X1 + i*per_thread));
  //   inputs2.push_back(const_cast<value_t*>(X2 + i*per_thread));

  //   sizes.push_back(m*per_thread);
  // }

  // if (ps*per_thread < m ) {
  //   inputs1.push_back(const_cast<value_t*>(X1 + ps*per_thread));
  //   inputs2.push_back(const_cast<value_t*>(X2 + ps*per_thread));
  //   sizes.push_back(m- ps*per_thread );
  // }


  inputs1.push_back(const_cast<value_t*>(X1));
  inputs2.push_back(const_cast<value_t*>(X2));
  sizes.push_back(m);
  std::cout << "here1" << std::endl;

  int num_devices = 0;
  int sentinel_device = 0;
  std::cout << "here2" << std::endl;

  CHECK_CUDA_ERROR(cudaGetDevice(&sentinel_device));
  CHECK_CUDA_ERROR(cudaGetDeviceCount(&num_devices));
  std::cout << "here3" << std::endl;

    std::cout << "here3.5 " << sentinel_device << " num devices " << num_devices << std::endl;


  std::vector<value_t*> per_device_x1;
  std::vector<value_t*> per_device_x2;
  std::cout << "here4" << std::endl;


  for (int i = 0; i < num_devices; i++) {
    value_t* new_ptr_x1= NULL;
    value_t* new_ptr_x2 = NULL;
      std::cout << "here5"  << i << std::endl;

    if (i != sentinel_device) {
            std::cout << "here6"  << i << std::endl;

      CHECK_CUDA_ERROR(cudaSetDevice(i));
      CHECK_CUDA_ERROR(cudaMalloc(&new_ptr_x1, m*n1*sizeof(value_t)));
      CHECK_CUDA_ERROR(cudaMalloc(&new_ptr_x2, m*n2*sizeof(value_t)));
        std::cout << "here6"  << i << std::endl;


      CHECK_CUDA_ERROR(cudaMemcpy(new_ptr_x1, X1, m*n1*sizeof(value_t) ,cudaMemcpyDeviceToDevice));
      CHECK_CUDA_ERROR(cudaMemcpy(new_ptr_x2, X2, m*n2*sizeof(value_t) ,cudaMemcpyDeviceToDevice));

      per_device_x1.push_back(new_ptr_x1);
      per_device_x2.push_back(new_ptr_x2);
      std::cout << "here7"  << i << std::endl;

      std::vector<value_t*> i1, i2;
      i1.push_back(new_ptr_x1);
      i2.push_back(new_ptr_x2);
      inputs1_vec.push_back(i1);
      inputs2_vec.push_back(i2);

    } else {
            std::cout << "here9"  << i << std::endl;

      per_device_x1.push_back(const_cast<value_t*>(X1));
      per_device_x2.push_back(const_cast<value_t*>(X2));
      std::cout << "here8"  << i << std::endl;

      std::vector<value_t*> i1, i2;
      i1.push_back(const_cast<value_t*>(X1));
      i2.push_back(const_cast<value_t*>(X2));
            std::cout << "here10"  << i << std::endl;

      inputs1_vec.push_back(i1);
      inputs2_vec.push_back(i2);

    }
  }
        std::cout << "here11"   << std::endl;

  CHECK_CUDA_ERROR(cudaSetDevice(sentinel_device));
      std::cout << "here12" << std::endl;

  rmm::device_uvector<int64_t> int64_indices(k * n_search_items, stream);
      std::cout << "here13"   << std::endl;


  #pragma omp parallel for num_threads(num_devices)
  for (int i = 0; i < num_devices; i++) {
          std::cout << "here14"<< std::endl;


    std::vector<value_t*> inputs1 = inputs1_vec[i];
    std::vector<value_t*> inputs2 = inputs2_vec[i];
          std::cout << "here16"  << i << std::endl;

    CHECK_CUDA_ERROR(cudaSetDevice(i));
          std::cout << "here15"  << i << std::endl;



    // devide such that devices equal work as posible + last device has leftover.
    size_t num_search_items_me = i == (num_devices - 1)? (n_search_items/num_devices) + (n_search_items%num_devices) :  (n_search_items/num_devices);
    size_t start_pos_idx = (n_search_items/num_devices)*i;
      std::cout << "here17.5   "  << i << std::endl;
      std::cout << "here17.6 " << per_device_x1.size () << " " <<  i   << std::endl;
      std::cout << "here17.7 " << per_device_x2.size() << " "<<  i    << std::endl;

    value_t* search_items_x1_local = per_device_x1[i] + n1*start_pos_idx;
    value_t* search_items_x2_local = per_device_x2[i] + n2*start_pos_idx;
      std::cout << "here17"  << i << std::endl;

    if (i!= sentinel_device ) {
            std::cout << "here18"  << i << std::endl;

          auto h = raft::handle_t(rmm::cuda_stream_per_thread, std::make_shared<rmm::cuda_stream_pool>());    
          rmm::device_uvector<int64_t> int64_indices_me(k * num_search_items_me, h.get_stream());
          rmm::device_uvector<value_t> dists_me(k * num_search_items_me, h.get_stream());
          brute_force_knn_GF(h, inputs1, inputs2, sizes, n1,n2, search_items_x1_local, search_items_x2_local, num_search_items_me, int64_indices_me.data(), dists_me.data(), k, true, true, metric);
      std::cout<< "here 29 "<< std::endl;

          CHECK_CUDA_ERROR(cudaMemcpy(dists + start_pos_idx*k, dists_me.data(), num_search_items_me*k*sizeof(value_t) ,cudaMemcpyDeviceToDevice));
                std::cout<< "here21 "<< std::endl;

          CHECK_CUDA_ERROR(cudaMemcpy(int64_indices.data() + start_pos_idx*k, int64_indices_me.data(), num_search_items_me*k*sizeof(int64_t) ,cudaMemcpyDeviceToDevice));
                std::cout<< "here22  "<< std::endl;

          CHECK_CUDA_ERROR(cudaFree(per_device_x1[i]));
                std::cout<< "here 23 "<< std::endl;

          
          CHECK_CUDA_ERROR(cudaFree(per_device_x2[i]));
    } else {
      std::cout<< "here20 "<< std::endl;
      brute_force_knn_GF(handle, inputs1, inputs2, sizes, n1,n2, search_items_x1_local, search_items_x2_local, num_search_items_me, int64_indices.data() +start_pos_idx*k, dists + start_pos_idx*k, k, true, true, metric);
            std::cout<< "here 19"<< std::endl;

    }
  }


  // This is temporary. Once faiss is updated, we should be able to
  // pass value_idx through to knn.

  // perform knn
  // brute_force_knn_GF(handle,
  //                 inputs1,
  //                 inputs2,
  //                 sizes,
  //                 n1,
  //                 n2,
  //                 const_cast<value_t*>(search_items1),
  //                 const_cast<value_t*>(search_items2),
  //                 n_search_items,
  //                 int64_indices.data(),
  //                 dists,
  //                 k,
  //                 true,
  //                 true,
  //                 metric);
  cudaSetDevice(sentinel_device);

  // convert from current knn's 64-bit to 32-bit.
  thrust::transform(exec_policy,
                    int64_indices.data(),
                    int64_indices.data() + int64_indices.size(),
                    inds,
                    [] __device__(int64_t in) -> value_idx { return in; });
}




/**
 * Constructs a mutual reachability graph, which is a k-nearest neighbors
 * graph projected into mutual reachability space using the following
 * function for each data point, where core_distance is the distance
 * to the kth neighbor: max(core_distance(a), core_distance(b), d(a, b))
 *
 * Unfortunately, points in the tails of the pdf (e.g. in sparse regions
 * of the space) can have very large neighborhoods, which will impact
 * nearby neighborhoods. Because of this, it's possible that the
 * radius for points in the main mass, which might have a very small
 * radius initially, to expand very large. As a result, the initial
 * knn which was used to compute the core distances may no longer
 * capture the actual neighborhoods after projection into mutual
 * reachability space.
 *
 * For the experimental version, we execute the knn twice- once
 * to compute the radii (core distances) and again to capture
 * the final neighborhoods. Future iterations of this algorithm
 * will work improve upon this "exact" version, by using
 * more specialized data structures, such as space-partitioning
 * structures. It has also been shown that approximate nearest
 * neighbors can yield reasonable neighborhoods as the
 * data sizes increase.
 *
 * @tparam value_idx
 * @tparam value_t
 * @param[in] handle raft handle for resource reuse
 * @param[in] X input data points (size m * n)
 * @param[in] m number of rows in X
 * @param[in] n number of columns in X
 * @param[in] metric distance metric to use
 * @param[in] k neighborhood size
 * @param[in] min_samples this neighborhood will be selected for core distances
 * @param[in] alpha weight applied when internal distance is chosen for
 *            mutual reachability (value of 1.0 disables the weighting)
 * @param[out] indptr CSR indptr of output knn graph (size m + 1)
 * @param[out] core_dists output core distances array (size m)
 * @param[out] out COO object, uninitialized on entry, on exit it stores the
 *             (symmetrized) maximum reachability distance for the k nearest
 *             neighbors.
 */
template <typename value_idx, typename value_t>
void mutual_reachability_graph(const raft::handle_t& handle,
                               const value_t* X,
                               size_t m,
                               size_t n,
                               raft::distance::DistanceType metric,
                               int min_samples,
                               value_t alpha,
                               value_idx* indptr,
                               value_t* core_dists,
                               raft::sparse::COO<value_t, value_idx>& out)
{
  RAFT_EXPECTS(metric == raft::distance::DistanceType::L2SqrtExpanded,
               "Currently only L2 expanded distance is supported");

  auto stream      = handle.get_stream();
  auto exec_policy = handle.get_thrust_policy();

  rmm::device_uvector<value_idx> coo_rows(min_samples * m, stream);
  rmm::device_uvector<value_idx> inds(min_samples * m, stream);
  rmm::device_uvector<value_t> dists(min_samples * m, stream);

  // perform knn
  compute_knn(handle, X, inds.data(), dists.data(), m, n, X, m, min_samples, metric);

  // Slice core distances (distances to kth nearest neighbor)
  core_distances<value_idx>(dists.data(), min_samples, min_samples, m, core_dists, stream);

  /**
   * Compute L2 norm
   */
  mutual_reachability_knn_l2(
    handle, inds.data(), dists.data(), X, m, n, min_samples, core_dists, (value_t)1.0 / alpha);

  // self-loops get max distance
  auto coo_rows_counting_itr = thrust::make_counting_iterator<value_idx>(0);
  thrust::transform(exec_policy,
                    coo_rows_counting_itr,
                    coo_rows_counting_itr + (m * min_samples),
                    coo_rows.data(),
                    [min_samples] __device__(value_idx c) -> value_idx { return c / min_samples; });

  raft::sparse::linalg::symmetrize(
    handle, coo_rows.data(), inds.data(), dists.data(), m, m, min_samples * m, out);

  raft::sparse::convert::sorted_coo_to_csr(out.rows(), out.nnz, indptr, m + 1, stream);

  // self-loops get max distance
  auto transform_in =
    thrust::make_zip_iterator(thrust::make_tuple(out.rows(), out.cols(), out.vals()));

  thrust::transform(exec_policy,
                    transform_in,
                    transform_in + out.nnz,
                    out.vals(),
                    [=] __device__(const thrust::tuple<value_idx, value_idx, value_t>& tup) {
                      return thrust::get<0>(tup) == thrust::get<1>(tup)
                               ? std::numeric_limits<value_t>::max()
                               : thrust::get<2>(tup);
                    });
}


template <typename value_idx, typename value_t>
void mutual_reachability_graph_GF(const raft::handle_t& handle,
                               const value_t* X1,
                               const value_t* X2,
                               size_t m,
                               size_t n1,
                               size_t n2,
                               raft::distance::DistanceType metric,
                               int min_samples,
                               value_t alpha,
                               value_idx* indptr,
                               value_t* core_dists,
                               raft::sparse::COO<value_t, value_idx>& out)
{
  RAFT_EXPECTS(metric == raft::distance::DistanceType::L2SqrtExpanded,
               "Currently only L2 expanded distance is supported");

  auto stream      = handle.get_stream();
  auto exec_policy = handle.get_thrust_policy();
  min_samples = 64;

  rmm::device_uvector<value_idx> coo_rows(min_samples * m, stream);
  rmm::device_uvector<value_idx> inds(min_samples * m, stream);
  rmm::device_uvector<value_t> dists(min_samples * m, stream);

  auto start = std::chrono::high_resolution_clock::now();

  // perform knn
  compute_knn_GF(handle, X1,X2, inds.data(), dists.data(), m, n1,n2, X1,X2, m, min_samples, metric);
  auto stop = std::chrono::high_resolution_clock::now();


  typedef std::chrono::duration<float> fsec;
  fsec fs = stop - start;
  auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(stop - start);


  std::cout << "Initial KNN Time: " << fs.count() << " milliseconds " << std::endl;
  std::cout << "Initial KNN Time: " << duration.count() << " milliseconds " << std::endl;


  
  //const value_t* X = X1;
  
  // Slice core distances (distances to kth nearest neighbor)
  core_distances<value_idx>(dists.data(), min_samples, 64, m, core_dists, stream);
   
  // /**
  //  * Compute L2 norm
  //  */
  // mutual_reachability_knn_l2(
  //   handle, inds.data(), dists.data(), X, m, n, min_samples, core_dists, (value_t)1.0 / alpha);

  // self-loops get max distance
  auto coo_rows_counting_itr = thrust::make_counting_iterator<value_idx>(0);
  thrust::transform(exec_policy,
                    coo_rows_counting_itr,
                    coo_rows_counting_itr + (m * min_samples),
                    coo_rows.data(),
                    [min_samples] __device__(value_idx c) -> value_idx { return c / min_samples; });

  raft::sparse::linalg::symmetrize(
    handle, coo_rows.data(), inds.data(), dists.data(), m, m, min_samples * m, out);

  raft::sparse::convert::sorted_coo_to_csr(out.rows(), out.nnz, indptr, m + 1, stream);

  // self-loops get max distance
  auto transform_in =
    thrust::make_zip_iterator(thrust::make_tuple(out.rows(), out.cols(), out.vals()));

  thrust::transform(exec_policy,
                    transform_in,
                    transform_in + out.nnz,
                    out.vals(),
                    [=] __device__(const thrust::tuple<value_idx, value_idx, value_t>& tup) {
                      return thrust::get<0>(tup) == thrust::get<1>(tup)
                               ? std::numeric_limits<value_t>::max()
                               : thrust::get<2>(tup);
                    });
}

};  // end namespace Reachability
};  // end namespace detail
};  // end namespace HDBSCAN
};  // end namespace ML