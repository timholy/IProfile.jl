include("sprofile.jl")
include("iprofile.jl")

module Profile
using SProfile
using IProfile

export @sprofile, sprofile_clear, sprofile_flat, sprofile_init, sprofile_tree, @iprofile

end
