# Libraries
library(philentropy)
library("Matrix")
library("clue")
library("aricode")
library("rio")
library("eList")
library(foreach)
library(doParallel)
library(doSNOW)
library(MASS)

source("Functions/update_steps.r")
source("Functions/utils.r")
source("Functions/bisilhouette.r")
source("Functions/spurious_bicl.r")

get_thresholds <- function(Xinput, Foutput, repeats){
    # shuffle data and 
    # find the threshold for removal of spurious biclusters
    #repeats: minimum value of 2
    n_views <- length(Xinput)
    n_clusts <- dim(Foutput[[1]])[2]
    k_input <- n_clusts * rep(1, length = n_views)
    x_mess <- vector(mode = "list", length = repeats)
    for (n in 1:repeats) {
      data_messed <- vector(mode = "list", length = n_views)
      for (i in 1:n_views){
          #correct shuffling
          dims <- dim(Xinput[[i]])
          data_messed[[i]] <- matrix(sample(Xinput[[i]]),
                                  dims[1], dims[2])
          while(any(colSums(data_messed[[i]])==0)| any(rowSums(data_messed[[i]])==0)){
              data_messed[[i]] <- matrix(sample(Xinput[[i]]),
                                       dims[1], dims[2])
          }
      }
      results <- restMultiNMTF_run(Xinput = data_messed,
               KK = k_input,  no_clusts = TRUE, stability = FALSE)
      x_mess[[n]] <- results$Foutput
    }
    avg_score <- c()
    max_score <- c()
    data <- vector(mode = "list", length = n_views)
    dens_list <- vector(mode = "list", length = n_views)
    d <- 1
    for (i in 1:n_views){
      scores <- c()
        for (j in 1:max(repeats - 1,1)){
          data[[i]] <- cbind(data[[i]], x_mess[[j]][[i]])
          for (k in 1:n_clusts){
            #jth repeat, ith view, kth cluster
            x1 <- ((x_mess[[j]])[[i]])[, k]
            for (l in (j + 1):repeats){
              for (m in 1:n_clusts){
                x2 <- ((x_mess[[l]])[[i]])[, m]
                max_val <- max(x1,x2)
                d1  <- density(x1, from=0, to=max_val)
                d2  <- density(x2, from=0, to=max_val)
                d1$y[d1$x>max(x1)] <- 0
                d2$y[d2$x>max(x2)] <- 0
                dens_list[[d]] <- d1
                scores <- c(scores,
                   suppressMessages(JSD(rbind(d1$y, d2$y), unit = "log2", est.prob="empirical")))
              }
            }
          }
      }
      data[[i]] <- cbind(data[[i]], x_mess[[repeats]][[i]])
      avg_score <- c(avg_score, mean(scores))
      #max_score <- c(max_score, max(scores))
      dens <- density(scores)
      max_score <- c(max_score, dens$x[which.max(dens$y)])
    }
  return(list("avg_score" = avg_score,
             "max_score" = max_score, "scores" = scores, "data" = data, "dens" = dens_list))
}

clustering_res_NMTF <- function(Xinput, Foutput,
               Goutput, Soutput, repeats, distance){
  #takes F,S,G returns clustering and removes 
  #spurious bicluster
  n_views <- length(Foutput)
  row_clustering <- vector("list", length = n_views)
  col_clustering <- vector("list", length = n_views)
  #check clustering and remove if necessary
  biclusts <- check_biclusters(Xinput, Foutput, repeats)
  for (i in 1:n_views) {
    row_clustering[[i]] <- apply(Foutput[[i]],
           2, function(x) as.numeric(x > (1 / dim(Foutput[[i]])[1])))

    col_clustering[[i]] <- apply(Goutput[[i]],
           2, function(x) as.numeric(x > (1 / dim(Goutput[[i]])[1])))
  }
  sil <- c()
  #update realtions and
  #set biclusters that aren't strong enough to 0
  #and if bicluster is empty set row and cols to 0
  for (i in 1:n_views){
     indices <- (((biclusts$score[i, ]) < biclusts$max_threshold[i])
                   | ((biclusts$score[i, ]) == 0))
     relations <- apply(Soutput[[i]], 1, which.max)
     new_indices <- indices[relations] # i==0, col cluster i isn't a bicluster
     row_clustering[[i]] <- row_clustering[[i]][, relations]
     row_clustering[[i]][, new_indices] <- 0
     col_clustering[[i]][, new_indices] <- 0
     sil <- c(sil,
       sil_score(Xinput[[i]], row_clustering[[i]], col_clustering[[i]], method=distance)$sil)
  }
  #calculate overall bisil
  sil <- ifelse(sum(sil)==0, 0, mean(sil[sil!=0]))
  return(list("row_clustering" = row_clustering,
      "col_clustering" = col_clustering, "sil" = sil))
}



#Application of ResNMTF to data!
restMultiNMTF_main <- function(Xinput, Finput = NULL, Sinput = NULL,
         Ginput = NULL, KK = NULL,
          phi = NULL, xi = NULL, psi = NULL,
          nIter = NULL, 
         repeats = 5, distance="euclidean", no_clusts = FALSE){
  #' Run Restrictive-Multi NMTF, following the above algorithm
  #' 
  #' 1. Normalise X^v s.t ||X||_1 = 1
  #' 2. Initialise F, S, G
  #' 3. Repeat for each view u
  #'    a. Fix ALL, update F^u
  #'    c. Fix ALL, update G^u
  #'    d. Fix ALL, update S^u
  #' until convergence
  n_v <- length(Xinput)
  
  # initialise F, S and G based on svd decomposition if not given
  if (is.null(Finput) | is.null(Ginput) | is.null(Sinput) ) {
        inits <- init_mats(Xinput, KK)
        currentF <- inits$Finit
        currentS <- inits$Sinit
        currentG <- inits$Ginit
        currentlam <- inits$lambda_init
        currentmu <- inits$mu_init
  }else {
    # Take Finit, Sinit, Ginit as the initialised latent representations
    currentF <- Finput
    currentS <- Sinput
    currentG <- Ginput
    currentlam <- lapply(currentF, colSums)
    currentmu <- lapply(currentG, colSums)
  }
  # Initialising additional parameters
  Xhat <- vector("list", length = n_v)
  # Update until convergence, or for nIter times
  if (is.null(nIter)){
    total_err <- c()
    # Run while-loop until convergence
    err_diff <- 1
    err_temp <- 0
    while ((err_diff > 1.0e-6)) {
      err <- numeric(length = n_v)
      new_parameters <- update_matrices(X = Xinput,
                                           Finput = currentF,
                                           Sinput = currentS,
                                           Ginput = currentG,
                                           lambda = currentlam,
                                           mu = currentmu,
                                           phi = phi,
                                           xi = xi,
                                           psi = psi)
      currentF <- new_parameters$Foutput
      currentS <- new_parameters$Soutput
      currentG <- new_parameters$Goutput
      currentlam <- new_parameters$lamoutput
      currentmu <- new_parameters$muoutput
      for (v in 1:n_v){
        Xhat[[v]] <- currentF[[v]] %*% currentS[[v]] %*% t(currentG[[v]])
        err[v] <- sum((Xinput[[v]] - Xhat[[v]])**2)/ sum((Xinput[[v]])**2)
      }
      mean_err <- mean(err)
      total_err <- c(total_err, mean_err)
      err_diff <- abs(mean_err - err_temp)
      err_temp <- tail(total_err, n = 1)
    }
  } else {
    total_err <- numeric(length = nIter)
    for (t in 1:nIter){
      err <- numeric(length = length(currentF))
      new_parameters <- update_matrices(X = Xinput,
                                           Finput = currentF,
                                           Sinput = currentS,
                                           Ginput = currentG,
                                           lambda = currentlam,
                                           mu = currentmu,
                                           phi = phi,
                                           xi = xi,
                                           psi = psi)
      currentF <- new_parameters$Foutput
      currentS <- new_parameters$Soutput
      currentG <- new_parameters$Goutput
      currentlam <- new_parameters$lamoutput
      currentmu <- new_parameters$muoutput
      for (v in 1:n_v){
        Xhat[[v]] <- currentF[[v]] %*% currentS[[v]] %*% t(currentG[[v]])
        err[v] <- sum((Xinput[[v]] - Xhat[[v]])**2)/ sum((Xinput[[v]])**2)
      }
      total_err[t] <- mean(err)
    }
  }
  for(v in 1:n_v){
        F_normal <- single_alt_l1_normalisation(currentF[[v]])
        currentF[[v]] <- F_normal$newMatrix
        G_normal <- single_alt_l1_normalisation(currentG[[v]])
        currentG[[v]] <- G_normal$newMatrix
        currentS[[v]] <- (F_normal$Q) %*% currentS[[v]] %*% G_normal$Q
  }

  Foutput <- currentF
  Soutput <- currentS
  Goutput <- currentG
  lam_out <- currentlam
  mu_out <- currentmu
  # if only need to obtain factorisation, return values now
  if (no_clusts) {
    return(list("Foutput" = Foutput, "Soutput" = Soutput,
              "Goutput" = Goutput))
  }
  # find clustering results and silhouette score
  clusters <- clustering_res_NMTF(Xinput, Foutput,
               Goutput, Soutput, repeats, distance)
  if (is.null(nIter)) {
    error <- mean(tail(total_err, n = 10))
  }else {
    error <- tail(total_err, n = 1)
  }
  return(list("Foutput" = Foutput, "Soutput" = Soutput,
              "Goutput" = Goutput, "Error" = error,
              "All_Error" = total_err, "Sil_score" = clusters$sil,
              "row_clusters" = clusters$row_clustering,
              "col_clusters" = clusters$col_clustering, 
              "lambda" = lam_out, 
              "mu" = mu_out))
}


##functions for stability selection

jaccard <- function(a, b) {
    #calculate jaccard between two vectors
    intersection <- length(intersect(a, b))
    union <-  length(a) + length(b) - intersection
    if (union == 0){
      return(0)
    }else{
      return(intersection / union)
    }
}

cart_prod <- function(a, b) {
  #returns cartesian product of two sets
  prod <- c()
  # check a or b are not empty sets
  if (length(a) == 0 || length(b) == 0) {
    return(NULL)
  }else{
    for (k in 1:length(a)){
      prod <- c(prod, paste(a[k], b))
    }
  return(prod)
  }
}
jaccard_results <- function(row_c, col_c, true_r, true_c, stability = FALSE){
  m <- ncol(row_c)
  n <- ncol(true_r)
  # if no biclusters detected but some are present
  # return 0
  # if no biclusters present but some are detected - score of 0
  m_0 <- sum(colSums(row_c) != 0) #no of clusters actually detected
  n_0 <- sum(colSums(true_r) != 0) #no of true clusters
  if ((m_0 == 0 && n_0 != 0) || (n_0 == 0 && m_0 != 0)) {
    if (stability) {
      return(0)
    }else{
      return(list("rec" = rep(0, 2), "rel" = rep(0, 2), "f_score" = rep(0, 2)))
    }
  }
  # if no biclusters present and none detected - score of 1
  if (m_0 == 0 && n_0 == 0) {
    if (stability) {
      return(1)
    }else{
      return(list("rec" = rep(1, 2), "rel" = rep(1, 2), "f_score" = rep(1, 2)))
    }
  }
  samps <- 1:nrow(row_c)
  feats <- 1:nrow(col_c)
  #initialise storage of jaccard index between pairs
  jac_mat <- matrix(0, nrow = m, ncol = n)
  for (i in 1:m){
    r_i <- samps[row_c[, i] == 1]
    c_i <- feats[col_c[, i] == 1]
    m_i <- cart_prod(r_i, c_i)
    for (j in 1:n){
        tr_i <- samps[true_r[, j] == 1]
        tc_i <- feats[true_c[, j] == 1]
        m_j <- cart_prod(tr_i, tc_i)
        jac_mat[i, j] <- jaccard(m_i, m_j)
    }
  }
  if (stability) {
    return(apply(jac_mat, 2, max))
  }
  rel <- ifelse(sum(apply(jac_mat, 1, max) != 0) == 0, 0,
    sum(apply(jac_mat, 1, max)) / m_0)
  rec <- ifelse(sum(apply(jac_mat, 2, max) != 0) == 0, 0, 
    sum(apply(jac_mat, 2, max)) / n_0)
  f <- ifelse(rel * rec == 0, 0, 2 * rel * rec / (rel + rec))
  return(list("rec" = rep(rec, 2), "rel" = rep(rel, 2), "f_score" = rep(f, 2)))
}

test_cond <- function(data, attempt){
  if(attempt==1){
    return(TRUE)
  }
  return(any(unlist(lapply(data, function(x) any(colSums(x)==0) | any(rowSums(x)==0)))))
}


stability_check <- function(Xinput, Sinput, results,
                     k, phi, xi, psi, nIter,
                     repeats, no_clusts, distance, sample_rate = 0.9,
                     n_stability = 5, stab_thres = 0.6, stab_test=FALSE){
    #check whether stability check even needs to be done
    #no_clusts_detected
    n_c <- sum(as.numeric(lapply(results$row_clusters,
             function(x) sum(colSums(x)))))
    if (n_c == 0){
      print("No biclusters detected!")
      return(results)
    }
    n_views <- length(Xinput)
    # initialise storage of results
    jacc <- matrix(0, nrow = n_views, ncol = k[1])
    jacc_rand <- matrix(0, nrow = n_views, ncol = k[1])
    for (t in 1:n_stability){
      new_data <- vector(mode = "list", length = n_views)
      row_samples <- vector(mode = "list", length = n_views)
      col_samples <- vector(mode = "list", length = n_views)
      #turn this into a function to be used with lapply

      dim <- dim(Xinput[[1]])
      attempt <- 1
      while(test_cond(new_data, attempt)){
        if(attempt==20){
          print("Unable to perform stability analysis due to sparsity of data.")
          return(results)
        }
        row_samples[[1]] <- sample(dim[1], (dim[1] * sample_rate))
        col_samples[[1]] <- sample(dim[2], (dim[2] * sample_rate))
        new_data[[1]] <- Xinput[[1]][row_samples[[1]], col_samples[[1]]]
        if(any(colSums(new_data[[1]])==0) | any(rowSums(new_data[[1]])==0)){
              zeros_cols <- colSums(new_data[[1]])!=0
              zeros_rows <- rowSums(new_data[[1]])!=0
              row_samples[[1]] <- row_samples[[1]][zeros_rows]
              col_samples[[1]] <- col_samples[[1]][zeros_cols]
              new_data[[1]] <- Xinput[[1]][row_samples[[1]], col_samples[[1]]]
        }
        if(n_views>1){
          for(i in 2:n_views){
            dims <- dim(Xinput[[i]])
            if((dims[1])==dim[1]){
              row_samples[[i]] <- row_samples[[1]]
            }else{
              row_samples[[i]] <- sample(dims[1], (dims[1] * sample_rate))
            }
            if((dims[2])==dim[2]){
              col_samples[[i]] <- col_samples[[1]]
            }else{
              col_samples[[i]] <- sample(dims[2], (dims[2] * sample_rate))
            }
            new_data[[i]] <- Xinput[[i]][row_samples[[i]], col_samples[[i]]]
            if(any(colSums(new_data[[i]])==0) | any(rowSums(new_data[[i]])==0)){
              zeros_cols <- colSums(new_data[[i]])!=0
              zeros_rows <- rowSums(new_data[[i]])!=0
              if((dims[1])==dim[1]){
                for(p in 1:i){
                  row_samples[[p]] <- row_samples[[p]][zeros_rows]
                }
              }else{
                row_samples[[i]] <- row_samples[[i]][zeros_rows]
              }
              if((dims[2])==dim[2]){
                for(p in 1:i){
                  col_samples[[p]] <- col_samples[[p]][zeros_cols]
                }
              }else{
                col_samples[[i]] <- col_samples[[i]][zeros_cols]
              }
              for(p in 1:i){
                  new_data[[p]] <- Xinput[[p]][row_samples[[p]], col_samples[[p]]]
                }
            }
            
        }
      }
      attempt <- attempt + 1
      }
      new_results <- restMultiNMTF_main(new_data, Finput = NULL, Sinput = NULL,
          Ginput = NULL, k,
          phi, xi, psi, nIter,repeats, distance)
      #compare results
      #extract results
      for(i in 1:n_views){
        jacc[i, ] <- jacc[i, ] + jaccard_results(new_results$row_clusters[[i]],
                 new_results$col_clusters[[i]],
              results$row_clusters[[i]][row_samples[[i]], ],
               results$col_clusters[[i]][col_samples[[i]], ], TRUE)
      }
    }
    jacc <- jacc / n_stability
    # jacc_rand <- jacc_rand / n_stability
    if(stab_test){
      return(list("res"=results,"jacc"=jacc))
    }else{
    for (i in 1:n_views){
      #set clusters not deemed stable to have 0 members
      results$row_clusters[[i]][, jacc[i, ] <  stab_thres] <- 0
      results$col_clusters[[i]][, jacc[i, ] <  stab_thres] <- 0
    }
    # results$Sil_score <- sil_score(Xinput,
    #               results$row_clusters, results$col_clusters, distance, TRUE)$overall
    # results$Sil_score <- sil_score(Xinput,
    #               results$row_clusters, results$col_clusters, distance, TRUE)$sil
    return(results)
      }
}


restMultiNMTF_run <- function(Xinput, Finput=NULL, Sinput=NULL, 
            Ginput=NULL, KK=NULL, phi=NULL, xi=NULL, psi=NULL, 
            nIter=NULL, k_min=3, k_max =8, distance= "euclidean",repeats = 5, no_clusts = FALSE, 
             sample_rate = 0.9, n_stability = 5, stability = TRUE, stab_thres = 0.4, stab_test=FALSE){

  #' @param k_max integer, default is 6, must be greater than 2, largest value of k to be considered initially,
  # initialise phi etc matrices as zeros if not specified
  # otherwise multiply by given parameter
  n_v <- length(Xinput)
  Xinput <- make_non_neg(Xinput)
  if (!typeof(Xinput[[1]]) == "double") {
    Xinput <- lapply(Xinput, function(x) as.matrix(x))
    }
  # Normalise Xinput
  Xinput <- lapply(Xinput, function(x) single_alt_l1_normalisation(x)$newMatrix)
  # initialise restriction matrices if not specified 
  # views with no restrictions require no input
  phi <- init_rest_mats(phi, n_v)
  psi <- init_rest_mats(psi, n_v)
  xi <- init_rest_mats(xi, n_v)
  # if number of clusters has been specified method can be applied straight away
  if ((!is.null(KK))) {
    results <- restMultiNMTF_main(Xinput, Finput, Sinput, Ginput,
                     KK, phi, xi, psi, nIter,
                      repeats, distance, no_clusts)
    # if using the original data, we want to perform stability analysis 
    # otherwise we want the results
    if (stability) {
      return(stability_check(Xinput,Sinput, results,
                     KK, phi, xi, psi, nIter,
                    repeats, no_clusts,distance, sample_rate,
                     n_stability, stab_thres))
    }else {
      return(results)
    }
  }
  # define set of k_s to consider
  KK <- k_min:k_max
  k_vec <- rep(1, n_v)
  n_k <- length(KK)
  #initialise storage of results
  # apply method for each k to be considered
  # how many jobs you want the computer to run at the same time
  #if on windows operating system - do normal for loop
  if ((.Platform$OS.type == "windows") |(.Platform$OS.type == "unix") ){
    res_list <- vector("list", length = n_k)
    for (i in 1:n_k){
      res_list[[i]] <- restMultiNMTF_main(Xinput, Finput, Sinput, Ginput,
                     KK[i] * k_vec, phi, xi, psi, nIter,
                     repeats, distance, no_clusts)
    }
  }else{
    # Get the total number of cores
    numberOfCores <- detectCores()
    # Register all the cores
    registerDoParallel(min(numberOfCores, length(KK)))
    res_list <- foreach(i = 1:length(KK)) %dopar% {
    restMultiNMTF_main(Xinput, Finput, Sinput, Ginput,
                     KK[i] * k_vec, phi, xi, psi, nIter,
                     repeats,distance, no_clusts)
  }
  }
  #extract scores
  err_list <- rep(0, length(KK))
  for (i in 1:length(KK)){
    err_list[i] <- res_list[[i]][["Sil_score"]][1]
  }
  #find value of k of lowest error
  test <- KK[which.max(err_list)]
  max_i <- k_max
  # if best performing k is the largest k considered
  # apply method to k + 1 until this is no longer the case
  if(k_min != k_max){
    while (test == max_i) {
    max_i <- max_i + 1
    KK <- c(KK, max_i)
    k <- max_i * k_vec
    new_l <- length(KK)
    res_list[[new_l]] <- restMultiNMTF_main(Xinput, Finput, Sinput, Ginput,
                     k, phi, xi, psi, nIter,
                     repeats, distance, no_clusts)
    err_list <- c(err_list, res_list[[new_l]][["Sil_score"]][1])
    test <- KK[which.max(err_list)]
  }
  }
  print(err_list)
  k <- which.max(err_list)
  results <- res_list[[k]]
  k_vec <- rep(KK[k], length = n_v)
  if(stability){
      return(stability_check(Xinput, Sinput, results,
                     k_vec, phi, xi, psi, nIter,
                    repeats, no_clusts, distance, sample_rate, n_stability, stab_thres, stab_test))
  }else{
        return(results)
  }
}
