connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*APU*"}
if {[catch {rst -srst} e]} { puts "SRST_FAIL: $e" } else { puts "SRST_OK" }
