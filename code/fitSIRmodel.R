args = commandArgs(trailingOnly=TRUE)

require(RJSONIO)
require(ggplot2)
require(tidyr)
require(deSolve)
require(pracma)
require(gridExtra)

sirObsFile <- args[1]
paramsOutFile <- args[2]
pngOutFile <- args[3]

optIters <- 10

get_sir_plot <- function(df) {
  dfg <- gather(df,key = 'group',value='people',Removed,Infected,Susceptible)
  dfg[dfg$people == 0,]$people <- 1e-05 # to avoid problems with log scale
  cols <- c("infected" = "red", "removed" = "green", "susceptible"="blue")
  res <-
    ggplot(dfg) +
    xlab("Days since year 2020 start") +
    geom_point(aes(x=day.num,y=people,color=group)) + scale_color_manual(values = cols)
  return(res)
}


SIR <- function(t, state, parameters) {
  with(as.list(c(state, parameters)),{
    # rate of change
    
    dS = -b*I*S/N
    dI = b*I*S/N - k*I
    dR = k*I
    
    # return the rate of change
    list(c(dS, dI, dR))
  })
}

obsSource <- read.csv(sirObsFile)

popCount <- obsSource$Susceptible[1]

obs <- data.frame(
  days=obsSource$dayNum,
  susceptible.obs=obsSource$Susceptible,
  infected.obs=obsSource$Infected,
  removed.obs=obsSource$Removed)

firstDayIdx <- which(obsSource$Infected>0)[1]

getPrediction <- function(p) {
  zeroDayNum = p[1]
  firstDayInfectedCount = abs(p[2])
  beta = abs(p[3]) # each infected individual has a fixed number "beta"  of contacts per day that are sufficient to spread the disease
  gamma = sigmoid(p[4]) # fixed fraction "gamma"  of the infected group will recover during any given day
  
  
  odeDays <- seq(zeroDayNum %/% 1, 366, by = 0.1)
  odeParameters <- c(b = beta, k=gamma, N=popCount)
  # R0 = b / k
  odeZeroState <- c(S=popCount, I = firstDayInfectedCount,R=0)
  
  out <- as.data.frame(ode(y = odeZeroState, times = odeDays, func = SIR, parms = odeParameters))
  names(out) <- c('days','susceptible.pred','infected.pred','removed.pred')
  
  out <- out[out$days %% 1 ==0,]
  out
}

getPredRunTable<-function(p) {
  out <- getPrediction(p)
  
  outMaxV <- max(out$infected.pred)
  outMaxDay <- out$days[which(out$infected.pred == outMaxV)]
  
  m1 <- merge(obs,out, by='days',all.x = T)
  
  # filling up out of range values
  erliestOut <- out[1,]
  latestOut <- out[nrow(out),]
  
  if(sum(is.na(m1$susceptible.pred) & m1$days<=erliestOut$days)>0)
    m1[is.na(m1$susceptible.pred) & m1$days<=erliestOut$days,]$susceptible.pred <- popCount
  if(sum(is.na(m1$susceptible.pred) & m1$days>=latestOut$days)>0)
    m1[is.na(m1$susceptible.pred) & m1$days>=latestOut$days,]$susceptible.pred <- latestOut$susceptible.pred
  
  if(sum(is.na(m1$infected.pred) & m1$days<=erliestOut$days)>0)
    m1[is.na(m1$infected.pred) & m1$days<=erliestOut$days,]$infected.pred <- 0
  if(sum(is.na(m1$infected.pred) & m1$days>=latestOut$days)>0)
    m1[is.na(m1$infected.pred) & m1$days>=latestOut$days,]$infected.pred <- latestOut$infected.pred
  
  if(sum(is.na(m1$removed.pred) & m1$days<=erliestOut$days)>0)
    m1[is.na(m1$removed.pred) & m1$days<=erliestOut$days,]$removed.pred <- 0
  if(sum(is.na(m1$removed.pred) & m1$days>=latestOut$days)>0)
    m1[is.na(m1$removed.pred) & m1$days>=latestOut$days,]$removed.pred <- latestOut$removed.pred
  
  
  res <- list(table =m1, peakDay = outMaxDay, peakHeight = outMaxV)
}

rmse <- function(suscept.obs,
                 infected.obs,
                 removed.obs,
                 susceptible.pred,
                 infected.pred,
                 removed.pred) {
  sqrt(mean(((susceptible.obs - susceptible.pred)**2 +
               (infected.obs - infected.pred)**2 +
               (removed.obs - removed.pred)**2)/3))
}

rmsle <- function(obs,pred) {
  log_obs <- log(obs+1)
  log_pred <- log(pred+1)
  sqrt(mean((log_obs-log_pred)*(log_obs-log_pred)))
}

tripple_rmsle <- function(suscept.obs,
                  infected.obs,
                  removed.obs,
                  susceptible.pred,
                  infected.pred,
                  removed.pred) {
  (
    rmsle(suscept.obs,susceptible.pred) +
    rmsle(infected.obs,infected.pred) +
    rmsle(removed.obs,removed.pred)
  )/3.0
}

toMinimize <- function(p) {
  pred <- getPredRunTable(p)
  
  m1 <- pred$table
  
  loss <- tripple_rmsle(
      m1$susceptible.obs,
      m1$infected.obs,
      m1$removed.obs,
      m1$susceptible.pred,
      m1$infected.pred,
      m1$removed.pred)
  return(loss)
}

optRes <- NULL
for(i in (1:optIters)) {
  # will try to fit several times with different seeds
  set.seed(12543 + 101*i)
  startP = c(firstDayIdx, # when the infection started
             as.integer(runif(1,min=1,max=10)), # how many infected on the first day
             runif(1), # beta
             runif(1))# gamma
  #print(toMinimize(startP)) # loss value at start
  optCtr <- list(trace=0,maxit=10000) # set trace to value higher than 0, if you want details
  curOptRes <- optim(startP, toMinimize,control = optCtr)
  if(curOptRes$convergence != 0)
    next; # we analyze only converged results
  if(is.null(optRes) || optRes$value > curOptRes$value) {
    optRes <- curOptRes
    print(paste0("Iteration ",i,": loss improved to ",optRes$value))
  } else {
    print(paste0("Iteration ",i,": loss did not improve (",curOptRes$value,")"))
  }
}

rmse = optRes$value
zeroDayNum = optRes$par[1]
firstDayInfectedCount = round(abs(optRes$par[2]))
beta = abs(optRes$par[3])
gamma = sigmoid(optRes$par[4])
r0 = beta/gamma

bestPrediction <- getPredRunTable(optRes$par)

paramsList <- list()
paramsList$rmse <- rmse
paramsList$zeroDayNum <- zeroDayNum
paramsList$firstDayInfectedCount <- firstDayInfectedCount
paramsList$beta <- beta
paramsList$gamma <- gamma
paramsList$TotalPopulation <- popCount
paramsList$r0 <- r0
paramsList$PeakInfectionValue <- bestPrediction$peakHeight
paramsList$PeakDay <- bestPrediction$peakDay

exportJson <- toJSON(paramsList)
write(exportJson, paramsOutFile)
print("written param file")

plotObsTable <- function(predTable,p) {
  predTableG <- gather(predTable,key="group",value='people',-days)
  predTableG$group <- as.factor(predTableG$group)
  
  # adding Type feaure : Actual or Model
  predTableG$Type <- 'Actual'
  predTableG[(predTableG$group == 'infected.pred') | (predTableG$group == 'removed.pred') | (predTableG$group == 'susceptible.pred'),]$Type <- 'Model'
  predTableG$Type <- as.factor(predTableG$Type)
  
  # adding Group feature: susceptible / infected / removed
  predTableG$Group <- 'Susceptible'
  predTableG[(predTableG$group == 'infected.obs') | (predTableG$group == 'infected.pred'),]$Group <- 'Infected'
  predTableG[(predTableG$group == 'removed.obs') | (predTableG$group == 'removed.pred'),]$Group <- 'Removed'
  predTableG$Group <- as.factor(predTableG$Group)
  
  if(sum(predTableG$people == 0)>0)
    predTableG[predTableG$people == 0,]$people <- 1e-5 # to avoid problems with log scale
  
  modelOnlyG <- predTableG[predTableG$Type == 'Model',]
  obsOnlyG <- predTableG[predTableG$Type == 'Actual',]
  
  cols <- c("Infected" = "red", "Removed" = "green", "Susceptible"="blue")
  shapes <- c("factor"=1)
  
  res <-
    p +
    xlab("Days since year 2020 start") +
    geom_point(aes(x=days,y=people,fill=Group),data=obsOnlyG, shape=21,color='transparent') + 
    scale_fill_manual(values = cols ,name="Observations") +
    theme_bw() #+
  res
}

plotPredTable <- function(predTable,p) {
  predTableG <- gather(predTable,key="group",value='people',-days)
  predTableG$group <- as.factor(predTableG$group)
  
  # adding Type feaure : Actual or Model
  predTableG$Type <- 'Actual'
  predTableG[(predTableG$group == 'infected.pred') | (predTableG$group == 'removed.pred') | (predTableG$group == 'susceptible.pred'),]$Type <- 'Model'
  predTableG$Type <- as.factor(predTableG$Type)
  
  # adding Group feature: susceptible / infected / removed
  predTableG$Group <- 'Susceptible'
  predTableG[(predTableG$group == 'infected.obs') | (predTableG$group == 'infected.pred'),]$Group <- 'Infected'
  predTableG[(predTableG$group == 'removed.obs') | (predTableG$group == 'removed.pred'),]$Group <- 'Removed'
  predTableG$Group <- as.factor(predTableG$Group)
  
  modelOnlyG <- predTableG[predTableG$Type == 'Model',]

  cols <- c("Infected" = "red", "Removed" = "green", "Susceptible"="blue")

  res <- p +
    scale_color_manual(values = cols,name="Model Prediction") +
    geom_line(aes(x=days,y=people,color=Group),data=modelOnlyG,size=0.5)
    
  #theme(legend.position = "bottom")
  res
}

max_val <- max(c(obsSource$Infected,obsSource$Removed)) * 1.1
latest_obs <- max(obsSource$dayNum) + 1
earliest_obs <- min(obsSource$dayNum)

obsFName <- basename(sirObsFile)
obsFName <- substr(obsFName,1,(nchar(obsFName)-4))
atPos = regexpr('@',obsFName)[1]
if(obsFName == 'globalSirTs') {
  descr <- "worldwide"
} else {
  if(atPos>1)
    province <- paste0(substr(obsFName,1,atPos-1),' - ')
  else
    province <- ''
  country <- substr(obsFName,atPos+1,nchar(obsFName))
  descr <-paste0(province, country)
}

p <- ggplot()
p <- plotObsTable(bestPrediction,p)
p <- plotPredTable(bestPrediction,p) +
  labs(title = paste0("SIR model fit [",descr,"]"),
       subtitle = paste0("R0 = ",round(r0,1),
              " beta = ",round(beta,2),
              ' gamma = ',round(gamma,2),
              ' RMSLE = ',round(rmse)))+
  scale_y_continuous(limits=c(0,max_val)) +
  scale_x_continuous(limits=c(earliest_obs,latest_obs))

p2 <- ggplot()
yearPred <- getPrediction(optRes$par)
p2 <- plotObsTable(bestPrediction,p2)
p2 <- plotPredTable(yearPred,p2)
p2 <- p2 + labs(title = "One year simulation",
                caption = "COVID-19 epidemic dynamics model") +
  guides(fill=FALSE, color=FALSE)


p3 <- grid.arrange(p, p2, nrow=2)

ggsave(pngOutFile,p3)
print("Done")