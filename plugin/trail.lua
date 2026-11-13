vim.api.nvim_create_user_command("Trail", function(args)
  require("trail").open(args.args)
end, { nargs = "?", desc = "Review base..head or a GitHub pull request (#123) with trail" })
