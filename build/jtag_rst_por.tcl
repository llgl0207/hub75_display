connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*APU*"}
if {[catch {rst -por} e]} { puts "POR_FAIL: $e" } else { puts "POR_OK" }
