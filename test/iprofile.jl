@iprofile begin
function f1(x::Int)
    k = 5
    l = 12
    y = sum(1:1000)
    for j = 1:100000
        z = j^2
    end
    if z > 0
        z = z-1
    elseif z == 0
        z = 1000
    else
        z = z+1
    end
    return x+1
end
function f1(x::Float64)
    return x+2
end

function f1{T}(x::T)
    return x+5
end
end #@iprofile begin
