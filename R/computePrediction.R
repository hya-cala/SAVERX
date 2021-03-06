#' Wrapper function for the autoencoder prediction + filtering step
#'
#' @inheritParams preprocessDat
#' @param use.pretrain Use a pretrained model or not
#' @param pretrained.weights.file If a pretrained model is used, provide the file storing the autoencoder model weights. It should have an extension of ".hdf5" and is the saved weights from the Python package \code{sctransfer}
#' @param clearup.python.session Whether to clear up everything in the Python session after computation or not. This clears up everything in Python, so you need to start a new R session to run \code{saverx} function again.
#' @param ... more arguments passed to \code{autoFilterCV}
#' @param is.large.data If the data is very large, it may take too much RAM and setting this parameter to True can reduce RAM by writing intermediate Python ouput files to disk instead of directly passing it to R. However, setting this to True can increase the computation time
#' @param batch_size batch size of the autoencoder. Default is NULL, where the batch size is automatically determined by \code{max(number of cells / 50, 32)}
#' 
#' @return RDS file saved for the autoencoder prediction + filtering result
#' @export
computePrediction <- function(out.dir,
                              input.file.name = NULL,
                              data.matrix = NULL,
                              data.species = c("Human", "Mouse", "Others"), 
                              use.pretrain = F,
                              pretrained.weights.file = "",
                              model.species = c("Human", "Mouse", "Joint"),
                              model.nodes.ID = NULL,
                              is.large.data = F,
                              clearup.python.session = T,
                              batch_size = NULL,
                              ...) {
	### inpute checking  ### 
  if (is.null(input.file.name) && is.null(data.matrix))
    stop("Either an input data file or an input matrix should be provided!")

  if (!is.null(input.file.name) && !is.null(data.matrix))
    stop("Only either an input data file or an input matrix should be provided!")

  if (!is.null(input.file.name)) {
    format <- strsplit(input.file.name, '[.]')[[1]]
    format <- paste(".", format[length(format)], sep = "")
    if (format != ".txt" && format != ".csv" && format != ".rds")
      stop("Input file must be in .txt or .csv or .rds form", call.=FALSE)
    print(paste("Input file is:", input.file.name))
  } else
    print("Input is a data matrix")
  if (use.pretrain)
    temp <- "Yes"
  else
    temp <- "No"
  print(paste("Use a pretrained model:", temp))
	
	data.species <- match.arg(data.species, c("Human", "Mouse", "Others"))
  if (use.pretrain)
    print(paste("Data species is:", data.species)) 	

	if (use.pretrain) {
		if (data.species == "Others")
			stop("For pretrained model, the data.species can only be Human or Mouse")
		if (!file.exists(pretrained.weights.file))
			stop("Can not find the pretrained model. Please make sure that pretrained.weights.file exists")
		print(paste("Pretrained weights file is:", pretrained.weights.file))
		model.species <- match.arg(model.species, c("Human", "Mouse", "Joint"))
    if (model.species == "Joint")
      model.species <- data.species
		print(paste("Model species is:", model.species))

	}
	######

  dir.create(out.dir, showWarnings = F)

	### preprocess data  ###
	if (use.pretrain && is.null(model.nodes.ID)) {
		if (model.species == "Human") {
	#		data(human_nodes_ID)
			model.nodes.ID <- human_nodes_ID
		} else {
	#		data(mouse_nodes_ID)
			model.nodes.ID <- mouse_nodes_ID
		}
	}
	preprocessDat(out.dir, input.file.name, 
          data.matrix,
				  data.species = data.species, 
				  model.species = model.species, 
				  model.nodes.ID = model.nodes.ID)
	

#	out_dir <- strsplit(text.file.name, split = "/")[[1]]
#	out_dir <- paste(out_dir[-length(out_dir)], collapse = "/")
#	if (out_dir == "")
#		  out_dir <- "."
	print("Data preprocessed ...")
	######

	### import Python module ###
	sctransfer <- reticulate::import("sctransfer", convert = F)
	main <- reticulate::import_main(convert = F)
	print("Python module sctransfer imported ...")
	######



	### run autoencoder ###
  if (is.large.data)
    write_output_to_tsv <- T
  else
    write_output_to_tsv <- F

	if (use.pretrain) {

    data <- readRDS(paste0(out.dir, "/tmpdata.rds"))

    est.mu <- Matrix::rowMeans(Matrix::t(Matrix::t(data$mat) / Matrix::colSums(data$mat)) * 10000)

    n.genes <- nrow(data$mat)
    err.autoencoder <- rep(NA, n.genes)
    err.const <- rep(NA, n.genes)
    n.cells <- ncol(data$mat)

    if (data.species == model.species)
      ID.use <- data$rowdata$internal_ID
    else
      ID.use <- data$rowdata$other_species_internal_ID
    rm(data)
    gc()

		x <- Matrix::readMM(paste0(out.dir, "/tmpdata.mtx"))
    if (is.null(batch_size))
      batch_size <- as.integer(max(ncol(x) / 50, 32))
    else
      batch_size <- as.integer(batch_size)

		nonmissing_indicator <- read.table(paste0(out.dir, "/tmpdata_nonmissing.txt"))$V1
    used.time <- system.time(result <- autoFilterCV(x, 
                                                    sctransfer,
                                                    main,
                                                    pretrain_file = pretrained.weights.file,
                                                    nonmissing_indicator = nonmissing_indicator, 
                                                    model.species = model.species, 
                                                    out_dir = out.dir,
                                                    batch_size = batch_size,
                                                    write_output_to_tsv = write_output_to_tsv,
                                                    ...))
		print(paste("Autoencoder total computing time is:", used.time[3], "seconds"))

		idx <- nonmissing_indicator == 1
		print(paste("Number of predictive genes is", sum(result$err.const[idx] > result$err.autoencoder[idx])))

		
		temp <- table(ID.use)
		id.not.unique <- names(temp[temp > 1])


#		est.mu <- est.mu %*% t(rep(1, n.cells))

		rownames(result$x.autoencoder) <- model.nodes.ID

		names(result$err.autoencoder) <- names(result$err.const) <- rownames(result$x.autoencoder)

		idx <- ID.use %in% model.nodes.ID[nonmissing_indicator == 1]
    result$x.autoencoder <- result$x.autoencoder[ID.use[idx], ]
    rownames(result$x.autoencoder) <- names(est.mu)[idx]
    tt <- est.mu[!idx] %*% t(rep(1, n.cells))
    rownames(tt) <- names(est.mu)[!idx]
    result$x.autoencoder <- rbind(result$x.autoencoder, tt)
    rm(tt)
    gc()
    result$x.autoencoder <- result$x.autoencoder[names(est.mu), , drop = F]

#		est.mu[idx, ] <- result$x.autoencoder[ID.use[idx], ]
		err.autoencoder[idx] <- result$err.autoencoder[ID.use[idx]]
    err.const[idx] <- result$err.const[ID.use[idx]]
		tmp <- suppressWarnings(file.remove(paste0(out.dir, "/tmpdata_nonmissing.txt")))
		tmp <- suppressWarnings(file.remove(paste0(out.dir, "/tmpdata.mtx")))
 #   result$x.autoencoder <- est.mu
    result$err.autoencoder <- err.autoencoder
		result$err.const <- err.const
	} else {
		data <- readRDS(paste0(out.dir, "/tmpdata.rds"))
    if (is.null(batch_size))
      batch_size <- as.integer(max(ncol(data$mat) / 50, 32))
    else
      batch_size <- as.integer(batch_size)

		used.time <- system.time(result <- autoFilterCV(data$mat, 
												 sctransfer, 
												 main,
												 out_dir = out.dir,
                         batch_size = batch_size,
                         write_output_to_tsv = write_output_to_tsv, 
												 ...))
    rm(data)
    gc()

		print(paste("Autoencoder total computing time is:", used.time[3], "seconds"))

		print(paste("Number of predictive genes is", sum(result$err.const > result$err.autoencoder)))
	}

  if (clearup.python.session) {
    reticulate::py_run_string("
import sys
sys.modules[__name__].__dict__.clear()")
    print("Python module cleared up.")
  }

  
  if (!use.pretrain || data.species == model.species) {
    temp.name <- paste0(out.dir, "/prediction.rds")
		saveRDS(result, file = temp.name)
    print(paste("Predicted + filtered results saved as:", temp.name))
	} else {
    temp.name <- paste0(out.dir, "/other_species_prediction.rds")
		saveRDS(result, file = temp.name)
    print(paste("Predicted + filtered results saved as:", temp.name))
	}
  tmp <- suppressWarnings(file.remove(paste0(out.dir, "/SAVERX_temp.mtx")))
  tmp <- suppressWarnings(file.remove(paste0(out.dir, "/SAVERX_temp_test.mtx")))
  if (is.large.data) {
    tmp <- suppressWarnings(file.remove(paste0(out.dir, "/SAVERX_temp_mean_norm.tsv")))
    tmp <- suppressWarnings(file.remove(paste0(out.dir, "/SAVERX_temp_pred_mean_norm.tsv")))
  }
   if (!use.pretrain)
      tmp <- suppressWarnings(file.remove(paste0(out.dir, "/SAVERX_temp_dispersion.tsv")))

}








