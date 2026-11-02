connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
puts "RESETTING"
catch {rst -system}
after 500
catch {con}
puts "RELEASED"
