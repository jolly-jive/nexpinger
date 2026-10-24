# :burrito tests need the built Linux binary; run them with `mix test --only burrito`
# :network tests send to the Internet with TTL 1 and need a gateway that returns
# Time Exceeded (IPv6 ones also need IPv6); run them with `mix test --only network`
ExUnit.start(exclude: [:burrito, :network])
