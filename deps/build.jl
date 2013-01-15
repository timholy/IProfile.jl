usr, bin = splitdir(JULIA_HOME)
base, tmp = splitdir(usr)
incpath = joinpath(base, "src")
run(`make INCPATH=$incpath`)
