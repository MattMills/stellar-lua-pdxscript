-- oracle/image.lua : an executable of the game, whichever kind it is: a Linux ELF (oracle/elf.lua)
-- or a Windows PE (oracle/pe.lua, its symbols from the .pdb next to it, else from labels).
--
--   local image = require("oracle.image").load(path)
--
-- For a Windows executable without a PDB the labels of stellar-fnmatch are used when
-- PDXORACLE_LABELS names their directory (files <build id>.csv) and PDXORACLE_CORPUS the
-- corpus.json that gives each build id's executable (oracle/labels.lua).

local imagelib = {}

-- imagelib.load(path [, options]) -> image (options go to pe.load)
function imagelib.load(path, options)
    local f = assert(io.open(path, "rb"))
    local head = f:read(4) or ""
    f:close()
    if head == "\127ELF" then
        return require("oracle.elf").load(path)
    elseif head:sub(1, 2) == "MZ" then
        options = options or {}
        local pe = require("oracle.pe")
        local image = pe.load(path, options)
        if not image.symbol_source and not options.no_symbols then
            local labels = require("oracle.labels")
            local csv, reference = labels.find(path)
            if csv then
                labels.apply(image, csv, { reference = reference })
                image.symbol_source = "labels"
            end
        end
        if not image.symbol_source and not options.no_symbols then
            error(tostring(path) .. ": no symbols (" .. (image.pdb_error and ("the PDB cannot be read: " ..
                image.pdb_error) or "no PDB, no labels") .. ")")
        end
        return image
    end
    error(tostring(path) .. ": neither an ELF nor a PE executable")
end

return imagelib
