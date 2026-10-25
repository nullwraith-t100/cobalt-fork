print("probe-main: iniciando")
local ok, err = pcall(function()
    print("probe-main: pcall funcionou")
end)
if not ok then
    warn("probe-main: pcall falhou: " .. tostring(err))
end
print("probe-main: fim")
