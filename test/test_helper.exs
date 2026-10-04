# :burrito tests need the built Linux binary; run them with `mix test --only burrito`
ExUnit.start(exclude: [:burrito])
