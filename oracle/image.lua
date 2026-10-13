-- oracle/image.lua : an executable of the game, whichever kind it is: a Linux ELF (oracle/elf.lua)
-- or a Windows PE (oracle/pe.lua, its symbols from the .pdb next to it, else from labels).
--
--   local image = require("oracle.image").load(path)
--
-- For a Windows executable without a PDB the labels of stellar-fnmatch are used when
-- PDXORACLE_LABELS names their directory (files <build id>.csv) and PDXORACLE_CORPUS the
-- corpus.json that gives each build id's executable (oracle/labels.lua). Without labels either,
-- PDXORACLE_TRANSFER names a build of the same architecture with a PDB whose symbols are carried
-- over (oracle/transfer.lua: the 32-bit Steam builds).

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
        if not image.symbol_source and not options.no_symbols and os.getenv("PDXORACLE_TRANSFER") then
            -- neither: the symbols of a build with a PDB, carried over (oracle/transfer.lua);
            -- PDXORACLE_TRANSFER is that build, or a chain "pdb build;b1;b2..." of builds each
            -- given the symbols of the one before (to reach versions far from the PDB build)
            local transfer = require("oracle.transfer")
            local chain = {}
            for step in os.getenv("PDXORACLE_TRANSFER"):gmatch("[^;]+") do
                local next_image = pe.load(step)
                if #chain > 0 and next_image.symbol_source ~= "pdb" then
                    -- nearest first: the build before it, then the ones before that
                    local refs = {}
                    for k = #chain, 1, -1 do refs[#refs + 1] = chain[k] end
                    transfer.apply(next_image, refs)
                    next_image.symbol_source = "transfer"
                end
                chain[#chain + 1] = next_image
            end
            if #chain > 0 and chain[1].bits == image.bits and chain[1].symbol_source == "pdb" then
                local refs = {}
                for k = #chain, 1, -1 do refs[#refs + 1] = chain[k] end
                transfer.apply(image, refs)
                image.symbol_source = "transfer"
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
