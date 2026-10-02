local uci=require("uci")

-- Hardened re-implementation of the stock uci_dhcp_host collector.
--
-- The stock collector passes a fixed set of labels ({name,dns,ip,duid}) to
-- metric(), including keys whose UCI value can be:
--   * nil        -> the exporter's print_metric() aborts mid-line on a nil
--                   label value, leaving a dangling `duid="` that then merges
--                   with the following metric's output (corrupt exposition,
--                   Prometheus scrape fails with "expected equal, got ...").
--   * a table    -> emitted literally as `table: 0x...`.
--   * odd chars  -> unescaped quotes/newlines break the line format.
--
-- This version drops empty labels, flattens tables, and escapes values.

local function sanitize(v)
  if v == nil then return nil end
  if type(v) == "table" then v = table.concat(v, " ") end
  v = tostring(v)
  v = v:gsub("\\", "\\\\")
  v = v:gsub('"', '\\"')
  v = v:gsub("[\r\n]", " ")
  return v
end

local function scrape()
  local curs=uci.cursor()
  local metric_uci_host = metric("uci_dhcp_host", "gauge")

  curs:foreach("dhcp", "host", function(s)
    local labels = {}
    for _, k in ipairs({"name", "dns", "ip", "duid"}) do
      local v = sanitize(s[k])
      if v ~= nil and v ~= "" then labels[k] = v end
    end

    if s["mac"] == nil then
      metric_uci_host(labels, 1)
      return
    end

    local macs = type(s["mac"]) == "table" and s["mac"] or {s["mac"]}
    for _, mac in ipairs(macs) do
      labels["mac"] = string.upper(mac)
      metric_uci_host(labels, 1)
    end
  end)
end

return { scrape = scrape }
