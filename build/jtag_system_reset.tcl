connect
puts [targets]
targets -set -nocase -filter {name =~ "APU"}
puts "RESETTING"
rst -system
after 2000
con
puts "RESET_DONE"
exit
