usr, bin = splitdir(JULIA_HOME)
jllib = joinpath(usr, "lib")
run(`make JULIALIBS=$jllib`)
