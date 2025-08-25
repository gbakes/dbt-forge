-- Simple test to verify message rotation works
local loading = require("dbt-forge.loading")

-- Show loading screen and let it run for 10 seconds
loading.show_loading("Testing Message Rotation")

-- Hide it after 10 seconds
vim.defer_fn(function()
  loading.hide_loading()
  print("Test complete - did you see the messages rotating?")
end, 10000)