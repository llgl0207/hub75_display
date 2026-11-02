connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100
puts "REBOOT_STATUS=[mrd 0xF8000258]"
puts "SWDT_CR=[mrd 0xF8005000]"
puts "SWDT_SR=[mrd 0xF8005004]"
puts "SWDT_RST=[mrd 0xF800500C]"
puts "CLK_621=[mrd 0xF80001C4]"
puts "DONE"
