######################################################################
## Step 1 - Download and Install H2O
######################################################################

# The following two commands remove any previously installed H2O packages for R.
if ("package:h2o" %in% search()) { detach("package:h2o", unload=TRUE) }
if ("h2o" %in% rownames(installed.packages())) { remove.packages("h2o") }

# Next, we download packages that H2O depends on.
# if (! ("methods" %in% rownames(installed.packages()))) { install.packages("methods") }
# if (! ("statmod" %in% rownames(installed.packages()))) { install.packages("statmod") }
# if (! ("stats" %in% rownames(installed.packages()))) { install.packages("stats") }
# if (! ("graphics" %in% rownames(installed.packages()))) { install.packages("graphics") }
# if (! ("RCurl" %in% rownames(installed.packages()))) { install.packages("RCurl") }
# if (! ("rjson" %in% rownames(installed.packages()))) { install.packages("rjson") }
# if (! ("tools" %in% rownames(installed.packages()))) { install.packages("tools") }
# if (! ("utils" %in% rownames(installed.packages()))) { install.packages("utils") }

# Now we download, install and initialize the H2O package for R.
install.packages("h2o", type="source", repos=(c("http://h2o-release.s3.amazonaws.com/h2o-dev/master/1112/R")))

# Install in R using devtools:install_github
#install.packages("devtools")
library(devtools)
#install_github("h2oai/h2o/R/ensemble/h2oEnsemble-package")
require(h2oEnsemble)

######################################################################
## Step 2 - Launch H2O
######################################################################

## Load h2o R module
library(h2o)

## Launch h2o on localhost, using all cores
h2oServer = h2o.init(nthreads=-1)

## Point to directory where the Kaggle data is
dir <- paste0("~/Dropbox (Personal)/Machine Learning/Otto/")
setwd(dir)
## For Spark/Hadoop/YARN/Standalone operation on a cluster, follow instructions on http://h2o.ai/download/
## Then connect to any cluster node from R

#h2oServer = h2o.init(ip="mr-0xd1",port=53322)
#dir <- "hdfs://mr-0xd6/users/arno/h2o-kaggle/otto/"


######################################################################
## Step 3 - Import Data and create Train/Validation Splits
######################################################################
train <- read.csv("train.csv", header=TRUE, sep = ",")
test <- read.csv("test.csv", header=TRUE, sep = ",")
train.hex <- as.h2o(train, conn = h2oServer, key = 'train.hex')
test.hex <- as.h2o(test, conn = h2oServer, key = 'test.hex')

# train.hex <- h2o.importFile(paste0(dir,"train.csv"), key="train.hex")
# test.hex <- h2o.importFile(paste0(dir, "test.csv"), key="test.hex")
dim(train.hex)
summary(train.hex)

predictors <- 2:(ncol(train.hex)-1) #ignore first column 'id'
response <- ncol(train.hex)

## Split into 80/20 Train/Validation
rnd <- h2o.runif(train.hex, 1234)
train_holdout.hex <- h2o.assign(train.hex[rnd<0.8,], "train_holdout.hex")
valid_holdout.hex <- h2o.assign(train.hex[rnd>=0.8,], "valid_holdout.hex")

######################################################################
## Step 4 - Use H2O Flow to inspect the data and build some models on 
## train_holdout.hex/valid_holdout.hex to get a feeling for the problem
######################################################################

## Connect browser to http://localhost:54321 (or http://cluster-node-ip:port)

######################################################################
## Step 5 - GBM Hyper-Parameter Tuning with Random Search
######################################################################

models <- c()
for (i in 1:30) {
  rand_numtrees <- sample(1:50,1) ## 1 to 50 trees
  rand_max_depth <- sample(5:15,1) ## 5 to 15 max depth
  rand_min_rows <- sample(1:10,1) ## 1 to 10 min rows
  rand_learn_rate <- 0.025*sample(1:10,1) ## 0.025 to 0.25 learning rate
  model_name <- paste0("GBMModel_",i,
                       "_ntrees",rand_numtrees,
                       "_maxdepth",rand_max_depth,
                       "_minrows",rand_min_rows,
                       "_learnrate",rand_learn_rate
  )
  model <- h2o.gbm(x=predictors, 
                   y=response, 
                   training_frame=train_holdout.hex,
                   validation_frame=valid_holdout.hex,
                   destination_key=model_name,
                   loss="multinomial",
                   ntrees=rand_numtrees, 
                   max_depth=rand_max_depth, 
                   min_rows=rand_min_rows, 
                   learn_rate=rand_learn_rate
  )
  models <- c(models, model)
}

## Find the best model (lowest logloss on the validation holdout set)
best_err <- 1e3
for (i in 1:length(models)) {
  err <- h2o.performance(models[[i]], valid_holdout.hex)@metrics$logloss
  if (err < best_err) {
    best_err <- err
    best_model <- models[[i]]
  }
}

## Show the "winning" parameters
parms <- best_model@allparameters
parms$ntrees
parms$max_depth
parms$min_rows
parms$learn_rate

## Training set performance metrics
train_perf <- h2o.performance(best_model, train_holdout.hex)
train_perf@metrics$cm$table
train_perf@metrics$logloss

## Validation set performance metrics
valid_perf <- h2o.performance(best_model, valid_holdout.hex)
valid_perf@metrics$cm$table
valid_perf@metrics$logloss

######################################################################
## Step 6 - Build Final GBM Model using the Full Training Data
######################################################################

gbm.model <- h2o.gbm(x=predictors, 
                 y=response,
                 destination_key="final_model",
                 training_frame=train.hex, 
                 loss="multinomial",
                 ntrees=43,
                 max_depth=9, 
                 min_rows=9,
                 learn_rate=0.125
)

######################################################################
## Step 7 - ANN Param Tuning with Random Search
######################################################################
ann.models <- c()
for (i in 1:30) {
  hidden_layer <- c(12, 12)*sample(7:25, 1)
  rand_epochs <- runif(1, 9, 13)
  model_name <- paste0("ANNModel_", i, 
                       "_nlayer", hidden_layer,
                       "_nepochs", rand_epochs
  )
  model <- h2o.deeplearning(x=predictors,
                            y=response,
                            training_frame = train_holdout.hex,
                            validation_frame = valid_holdout.hex,
                            loss = 'CrossEntropy',
                            hidden = hidden_layer,
                            rate = 0.005, 
                            epochs = rand_epochs
 )
 ann.models <- c(ann.models, model)
}

## Find the best model (lowest logloss on the validation holdout set)
best_err <- 1e3
for (i in 1:length(ann.models)) {
  err <- h2o.performance(ann.models[[i]], valid_holdout.hex)@metrics$logloss
  if (err < best_err) {
    best_err <- err
    best_model <- ann.models[[i]]
  }
}

## Show the "winning" parameters
parms <- best_model@allparameters
parms$hidden
parms$epochs

######################################################################
## Step 8 - Build Final ANN Model using the Full Training Data
######################################################################
ann.model <- h2o.deeplearning(x=predictors,
                              y=response,
                              training_frame = train_holdout.hex,
                              #loss = 'CrossEntropy',
                              hidden = c(120, 120),
                              rate = 0.005, 
                              epochs = 10.87304)
#180 180 9.864638

######################################################################
## Step 9 - Make Final Ensemble combining GBM and ANN 
######################################################################
learner <- c("gbm.model", "ann.model")
metalearner <- c("SL.glm")

fit <- h2o.ensemble(x=predictors,
                    y=response,
                    data=train_holdout.hex,
                    family = 'binomial',
                    learner = learner,
                    metalearner = metalearner)

######################################################################
## Step 9 - Make Final Test Set Predictions for Submission
######################################################################

## Predictions: label + 9 per-class probabilities
pred <- predict(model, test.hex)
head(pred)

## Remove label
pred <- pred[,-1]
head(pred)

## Paste the ids (first col of test set) together with the predictions
submission <- h2o.cbind(test.hex[,1], pred)
head(submission)

## Save submission to disk
h2o.exportFile(submission, "submission.csv")
write.csv(as.data.frame(submission), file = "submission.csv")
