connect -url TCP:127.0.0.1:3121
catch {targets 1}
if {[catch {rst -system} e]} { puts "RST_FAIL $e" } else { puts "RST_OK" }
after 1000
catch {con}
puts "RST_DONE"
