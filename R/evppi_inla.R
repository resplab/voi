## Code taken from BCEA package
## Baio, G., Berardi, A., & Heath, A. (2017). Bayesian cost-effectiveness analysis with the R package BCEA. New York: Springer.
## https://github.com/giabaio/BCEA

check_packages <- function(){
    if (!isTRUE(requireNamespace("INLA", quietly = TRUE))) {
        stop("You need to install the packages 'INLA' and 'splancs'. Please run in your R terminal:\n install.packages('INLA', repos='https://inla.r-inla-download.org/R/stable')\n and\n install.packages('splancs')")
    }
    if (!isTRUE(requireNamespace("ldr", quietly = TRUE))) {
        stop("You need to install the package 'ldr'. Please run in your R terminal:\ninstall.packages('devtools')\ndevtools::install_version('ldr', version = '1.3.3', repos = 'http://cran.rstudio.com')")
    }
}

## TODO int.ord - allow different ones for costs and effects 

fitted_inla <- function(y, inputs, pars,
                        verbose = TRUE,
                        cutoff = 0.3,
                        convex.inner = -0.4,
                        convex.outer = -0.7,
                        max.edge = 0.7,
                        plot_inla_mesh = FALSE,
                        h.value = 5e-05,
                        robust = FALSE,
                        int.ord = 1){
#    stop("INLA EVPPI method currently unavailable, as the `ldr` package has been removed from CRAN")
    check_packages()
    family <- if (robust) "T" else "gaussian"
    if (!is.element("INLA", (.packages()))) {
        attachNamespace("INLA")
    }
    if (length(pars)<2){
        stop("The INLA method can only be used with 2 or more parameters")
    }
    if (verbose) {
        message("Finding projections")
    }
    projections <- make.proj(parameter = pars, inputs = inputs, x = y)
    data <- projections$data
    if (verbose) {
        message("Determining Mesh")
    }
    mesh <- make.mesh(data = data, convex.inner = convex.inner,
                      convex.outer = convex.outer, cutoff = cutoff,max.edge=max.edge)
    plot.mesh(mesh = mesh$mesh, data = data, plot = plot_inla_mesh)
    if (verbose) {
        message("Calculating fitted values for the GP regression using INLA/SPDE")
    }
    fit <- fit.inla(parameter = pars, inputs = inputs,
                    x = y, mesh = mesh$mesh, data.scale = data, int.ord = int.ord,
                    convex.inner = convex.inner, convex.outer = convex.outer,
                    cutoff = cutoff, max.edge = max.edge, h.value = h.value, family=family)
    fit$fitted
}




###INLA Fitting
make.proj <- function(parameter, inputs, x) {
    tic <- proc.time()
    scale<-8/(range(x)[2]-range(x)[1])
    scale.x <- scale*x -mean(scale*x)
    bx<-ldr::bf(scale.x,case="poly",2)
    fit1<-ldr::pfc(scale(inputs[,parameter]),scale.x,bx,structure="iso")
    fit2<-ldr::pfc(scale(inputs[,parameter]),scale.x,bx,structure="aniso")
    fit3<-ldr::pfc(scale(inputs[,parameter]),scale.x,bx,structure="unstr")
    struc<-c("iso","aniso","unstr")[which(c(fit1$aic,fit2$aic,fit3$aic)==min(fit1$aic,fit2$aic,fit3$aic))]
    AIC.deg<-array()
    for(i in 2:7){
        bx<-ldr::bf(scale.x,case="poly",i)
        fit<-ldr::pfc(scale(inputs[,parameter]),scale.x,bx,structure=struc)
        AIC.deg[i]<-fit$aic}
    deg<-which(AIC.deg==min(AIC.deg,na.rm=T))
    d<-min(dim(inputs[,parameter])[2],deg)
    by<-ldr::bf(scale.x,case="poly",deg)
    comp.d<-ldr::ldr(scale(inputs[,parameter]),scale.x,bx,structure=struc,model="pfc",numdir=d,numdir.test=T)
    dim.d<-which(comp.d$aic==min(comp.d$aic))-1
    comp<-ldr::ldr(scale(inputs[,parameter]),scale.x,bx,structure=struc,model="pfc",numdir=2)
    toc <- proc.time() - tic
    time <- toc[3]
    if(dim.d>2){
        warning(paste("The dimension of the sufficient reduction is",dim.d,".
                    Dimensions greater than 2 imply that the EVPPI approximation using INLA may be inaccurate.
                    Full residual checking using diag.evppi is required."))}
    names(time) = "Time to fit find projections (seconds)"
    list(data = comp$R, time = time,dim=dim.d)
}


plot.mesh <- function(mesh, data, plot) {
    if (plot == TRUE || plot == T) {
        cat("\n")
        choice <- select.list(c("yes", "no"), title = "Would you like to save the graph?",
                              graphics = F)
        if (choice == "yes") {
            exts <- c("jpeg", "pdf", "bmp", "png", "tiff")
            ext <- select.list(exts, title = "Please select file extension",
                               graphics = F)
            name <- paste0(getwd(), "/mesh.", ext)
            txt <- paste0(ext, "('", name, "')")
            eval(parse(text = txt))
            plot(mesh)
            points(data, col = "blue", pch = 19, cex = 0.8)
            dev.off()
            txt <- paste0("Graph saved as: ", name)
            cat(txt)
            cat("\n")
        }
        cat("\n")
        plot(mesh)
        points(data, col = "blue", pch = 19, cex = 0.8)
    }
}


make.mesh <- function(data, convex.inner, convex.outer,
                      cutoff,max.edge) {
    tic <- proc.time()
    inner <- suppressMessages({
        INLA::inla.nonconvex.hull(data, convex = convex.inner)
    })
    outer <- INLA::inla.nonconvex.hull(data, convex = convex.outer)
    mesh <- INLA::inla.mesh.2d(
        loc=data, boundary=list(inner,outer),
        max.edge=c(max.edge,max.edge),cutoff=c(cutoff))
    toc <- proc.time() - tic
    time <- toc[3]
    names(time) = "Time to fit determine the mesh (seconds)"
    list(mesh = mesh, pts = data, time = time)
}


fit.inla <- function(parameter, inputs, x, mesh,
                     data.scale, int.ord, convex.inner, convex.outer,
                     cutoff, max.edge,h.value,family) {
    tic <- proc.time()

    inputs <- inputs[,parameter,drop=FALSE]
    inputs.scale <- scale(inputs, apply(inputs, 2, mean), apply(inputs, 2, sd))
    scale<-8/(range(x)[2]-range(x)[1])
    scale.x <- scale*x -mean(scale*x)
    A <- INLA::inla.spde.make.A(mesh = mesh, loc = data.scale, silent = 2L)
    spde <- INLA::inla.spde2.matern(mesh = mesh, alpha = 2)
    stk.real <- INLA::inla.stack(tag = "est", data = list(y=scale.x), A = list(A, 1),
                                 effects = list(s = 1:spde$n.spde,
                                                data.frame(b0 = 1, x = cbind(data.scale, inputs.scale))))
    data <- INLA::inla.stack.data(stk.real)
    ctr.pred <- INLA::inla.stack.A(stk.real)
    inp <- paste("x", parameter, sep=".") # CJ 
#    inp <- names(stk.real$effects$data)[parameter + 4] # BCEA 
    form <- paste(inp, "+", sep = "", collapse = "")
    formula <- paste("y~0+(", form, "+0)+b0+f(s,model=spde)",
                     sep = "", collapse = "")
    if (int.ord[1] > 1) {
        formula <- paste("y~0+(", form, "+0)^", int.ord[1],
                         "+b0+f(s,model=spde)", sep = "", collapse = "")
    }
    Result <- suppressMessages({
        INLA::inla(as.formula(formula), data = data,
                   family = family, control.predictor = list(A = ctr.pred,link = 1),
                   control.inla = list(h = h.value),
                   control.compute = list(config = T), verbose = TRUE)
    })
    fitted <- (Result$summary.linear.predictor[1:length(x),"mean"]+mean(scale*x))/scale
    fit <- Result
    toc <- proc.time() - tic
    time <- toc[3]
    names(time) = "Time to fit INLA/SPDE (seconds)"
    list(fitted = fitted, model = fit, time = time, formula = formula,
         mesh = list(mesh = mesh, pts = data.scale))
}
