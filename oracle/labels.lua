-- oracle/labels.lua : symbols for a Windows build without a PDB, from the labels of stellar-fnmatch
-- (a CSV per build: rva, end, size, score, second, round, evidence, label; a label is a qualified
-- name without parameters, "A | B" when identical functions were folded into one).
-- Filled in below.

local labels = {}

function labels.find(path)
    return nil
end

function labels.apply(image, csv, options)
    error("labels: not implemented")
end

return labels
