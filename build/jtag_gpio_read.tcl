connect
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100
puts "A040 [mrd 0xE000A040]"
puts "A060 [mrd 0xE000A060]"
puts "A204 [mrd 0xE000A204]"
puts "A208 [mrd 0xE000A208]"
puts "720 [mrd 0xF8000720]"
puts "728 [mrd 0xF8000728]"
puts "73C [mrd 0xF800073C]"
puts "102C [mrd 0xE010102C]"
puts "1024 [mrd 0xE0101024]"
con
exit
