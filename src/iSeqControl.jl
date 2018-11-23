module iSeqControl
using Sockets
abstract type Device end

struct NHQ_206L <: Device
    name::String
    ip::String
    port::Int

    function NHQ_206L(name::String, ip::String, port::Int)
        device = new(name, ip, port)
        return device
    end

    function Base.show(io::IO, device::NHQ_206L)
      for n in fieldnames(typeof(device))
        println(io, "$n: $(getfield(device,n))")
      end
    end
end

export NHQ_206L

struct NHQ_226L <: Device
    name::String
    ip::String
    port::Int

    function NHQ_226L(name::String, ip::String, port::Int)
        device = new(name, ip, port)
        return device
    end

    function Base.show(io::IO, device::NHQ_226L)
      for n in fieldnames(typeof(device))
        println(io, "$n: $(getfield(device,n))")
      end
    end
end
const NHQ_Module = Union{NHQ_206L, NHQ_226L}

export NHQ_226L

CRLF = "\r\n"
function query(device::NHQ_Module, cmd::String; timeout=1.0)::String
    c = -1
    while c == -1
        try
            c = connect(device.ip,device.port)
            println("Connection Successful")
            break
        catch err
            println(err)
        end
        sleep(0.5)
    end
    write(c, CRLF) # to assure synchronization
    readline(c)
    if typeof(device)==NHQ_226L
        readline(c)
    end
    cmd = "$cmd$CRLF"
    for char in cmd
        sleep(0.2)
        write(c, char)
    end
    t0 = time()
    t = 0.
    r=""
    task = @async (readline(c);; r=readline(c))
    while t < timeout
        if task.state == :done break end
        t = time()-t0
        sleep(0.01)
    end
    if typeof(device)==NHQ_206L
        r=readline(c)
    end
    close(c)
    if t >= timeout
        error("Timeout! Device did not answer.")
    else
        return r
    end
end

function set(device::NHQ_Module, cmd::String)
    c = -1
    while c == -1
        try
            c = connect(device.ip,device.port)
            break
        catch err
            println(err)
        end
        sleep(0.5)
    end
    write(c, CRLF) # to assure synchronization
    readline(c)
    if typeof(device)==NHQ_226L
        readline(c)
    end
    cmd = "$cmd\r\n"
    for char in cmd
        sleep(0.2)
        write(c, char)
    end
    close(c)
    nothing
end

function get_device_information(device::NHQ_Module; timeout=7.)::Array{SubString}
    return split(query(device, "#"),";")
end
export show_device_information
function show_device_information(device::NHQ_Module)
    di = get_device_information(device)
    println("Serial number: $(di[1])")
    date = Date(di[2], "mm.yy")+Dates.Year(2000)
    println("Software release: $(Dates.year(date))-$(Dates.monthname(date))")
    println("Max. voltage: $(di[3])")
    println("Max. current: $(di[4])")
    nothing
end

CHANNELS = Dict{Symbol, Int}(
    :A => 1,
    :B => 2
)
function get_channel(channel::Symbol)
    if in(channel, keys(CHANNELS))
        chn = CHANNELS[channel]
    else
        error("'channel' must be ':A' or ':B'.\n $(CHANNELS)")
    end
end

"""
# get_status(device::NHQ_Module)

Reads out the status from the module device.
'channel' can be ':A' or ':B' (channel 1 or 2).
"""
function get_status(device::NHQ_Module, channel::Symbol)
    try
        chn = get_channel(channel)
        return query(device, "S$chn")[4:end]
    catch err
        #warn(err)
        return "unknown"
    end
end
function show_status(status::String)
    s="unknown"
    for (key, value) in STATUS_INFORMATION
        occursin(status, key) ? s=value : nothing
    end
    if s=="unknown"
        println("Unknown status reply: $status")
    else
        println(status, " => ", s)
    end
    nothing
end
function show_status(device::NHQ_Module, channel::Symbol)
    status = get_status(device, channel)
    show_status(status)
    nothing
end

export show_status

STATUS_INFORMATION = Dict{String, String}(
    "ON"  => "Output voltage according to set voltage",
    "OFF" => "Channel front panel switch off",
    "MAN" => "Channel is on, set to manual mode",
    "ERR" => "V_max or I_max is or was exceeded",
    "INH" => "Inhibit signal is or was active",
    "QUA" => "Quality of output voltage not given at present",
    "L2H" => "Output voltage increasing",
    "H2L" => "Output voltage decreasing",
    "LAS" => "Look at Status (only after G-command)",
    "TRP" => "Current trip was active"
)

ERROR_CODES = Dict{String, String}(
    "????" => "Syntax error",
    "?WCN" => "Wrong channel number",
    "?TOT" => "Timeout error (with following reinitialization)",
    "? UMX=nnnn" => "Set voltage exceeds voltage limit, max. possible value is nnnn" # ... can be improved
)


"""
# get_voltage(device::NHQ_Module, channel::Symbol)

Reads out the actual voltage from the module 'device' in units V.
'channel' can be ':A' or ':B' (channel 1 or 2).
"""
function get_measured_voltage(device::NHQ_Module, channel::Symbol)
    try
        chn = get_channel(channel)
        r = query(device, "U$chn")
        reg_1 = r"[0-9]+[+-]" # newer firmware version
        reg_2 = r"[+-]{0,1}[0-9]*" # newer firmware version
        if ismatch(reg_1, r)
            m = match(reg_1, r)
            voltage = parse(Float64, r[1:(m.offset+length(m.match)-2)])
            exp = parse(Int, r[(m.offset+length(m.match))-1:(end)])
            return voltage*(10.0^exp)
        elseif ismatch(reg_2, r)
            m = match(reg_2, r)
            return parse(Int, m.match)
        else
           # warn("unknown return (pattern) of device: $r")
        end
    catch err
        println(err)
        #warn(err)
        return;
    end
end
export get_measured_voltage
"""
# get_current(device::NHQ_Module, channel::Symbol)

Reads out the actual current from the module 'device' in units A.
'channel' can be ':A' or ':B' (channel 1 or 2).
"""
function get_measured_current(device::NHQ_Module, channel::Symbol)
    try
        chn = get_channel(channel)
        r = query(device, "I$chn")
        reg = r"[0-9]+[+-]"
        m = match(reg, r)
        voltage = parse(Float64, r[1:(m.offset+length(m.match)-2)])
        exp = parse(Int, r[(m.offset+length(m.match))-1:(end)])
        return voltage*(10.0^exp)
    catch err
        println(err)
       # warn(err)
        return;
    end
end
export get_measured_current
"""
# get_target_voltage(device::NHQ_Module, channel::Symbol)

Reads out the target (set) voltage from the module 'device' in units V.
'channel' can be ':A' or ':B' (channel 1 or 2).
"""
function get_target_voltage(device::NHQ_Module, channel::Symbol)
    try
        chn = get_channel(channel)
        r = query(device, "D$chn")
        reg_1 = r"[0-9]+[+-]" # newer firmware version
        reg_2 = r"[+-]{0,1}[0-9]*" # newer firmware version
        if ismatch(reg_1, r)
            m = match(reg_1, r)
            voltage = parse(Float64, r[1:(m.offset+length(m.match)-2)])
            exp = parse(Int, r[(m.offset+length(m.match))-1:(end)])
            return voltage*(10.0^exp)
        elseif ismatch(reg_2, r)
            m = match(reg_2, r)
            return parse(Int, m.match)
        else
            error("unknown return (pattern) of device: $r")
        end
    catch err
      #  warn(err)
        return missing
    end
end

export get_target_voltage
"""
# set_voltage(device::NHQ_Module, channel::Symbol)

Sets the target voltage from the module 'device' in units V.
'channel' can be ':A' or ':B' (channel 1 or 2).
"""
function set_voltage(device::NHQ_Module, channel::Symbol, value::Real)
    chn = get_channel(channel)
    current_target_voltage = query(device, "D$chn")
    if occursin(".", current_target_voltage) # new firmware version
        cmd = "D$chn=$(round(Int,value))"
        set(device, cmd)
    else # old firmware version
        println("Old firmware")
        v = convert(Int, round(Int,value))
        cmd = "D$chn=$(lpad(v, 4, 0))" # leading zeros, 4 digits
        set(device, cmd)
    end
     sleep(0.05)
     #println("New target voltage is: $(get_target_voltage(device, channel)) V")
    nothing
end

export set_voltage

"""
# get_voltage_limit(device::NHQ_Module, channel::Symbol)

Reads out the maximum output voltage from the module 'device' in units 1.
'channel' can be ':A' or ':B' (channel 1 or 2).
"""
function get_voltage_limit(device::NHQ_Module, channel::Symbol)
    chn = get_channel(channel)
    r = query(device, "M$chn")
    return parse(Float64, r)/100
end

export get_voltage_limit
"""
# get_current_limit(device::NHQ_Module, channel::Symbol)

Reads out the maximum output current from the module 'device' in units 1.
'channel' can be ':A' or ':B' (channel 1 or 2).
"""
function get_current_limit(device::NHQ_Module, channel::Symbol)
    chn = get_channel(channel)
    r = query(device, "N$chn")
    return parse(Float64, r)/100
end

export get_current_limit

"""
# get_ramp_speed(device::NHQ_Module, channel::Symbol)

Reads out the ramp speed from the module 'device' in units V/s.
'channel' can be ':A' or ':B' (channel 1 or 2).
"""
function get_ramp_speed(device::NHQ_Module, channel::Symbol)
    try
        chn = get_channel(channel)
        r = query(device, "V$chn")
        try
            value = parse(Int, r)
            return value
        catch
            error("unknown response (pattern): $r")
        end
    catch err
      #  warn(err)
        return missing
    end
end

export get_ramp_speed
"""
# set_ramp_speed(device::NHQ_Module, channel::Symbol)

Sets the ramp speed from the module 'device' in units V/s.
'channel' can be ':A' or ':B' (channel 1 or 2).
"""
function set_ramp_speed(device::NHQ_Module, channel::Symbol, value::Int)
    if !( 2 <= value <= 255) error("value must be an integer in [2, 255]. It was $value") end
    chn = get_channel(channel)
    cmd = "V$chn=$(lpad(value, 3, 0))" # leading zeros, 3 digits, not sure if needed but it works
    set(device, cmd)
    nothing
end

export set_ramp_speed

"""
# start_voltage_ramp(device::NHQ_Module, channel::Symbol)

Starts ramping up the voltage of module 'device'.
'channel' can be ':A' or ':B' (channel 1 or 2).
"""
function start_voltage_ramp(device::NHQ_Module, channel::Symbol)
    chn = get_channel(channel)
    cmd = "G$chn"
    set(device, cmd)
    nothing
end

export start_voltage_ramp
"""
# get_auto_start_state(device::NHQ_Module, channel::Symbol)

Reads out the state of the auto start option.
'channel' can be ':A' or ':B' (channel 1 or 2).
"""
function get_auto_start_state(device::NHQ_Module, channel::Symbol)
    chn = get_channel(channel)
    r = query(device, "A$chn")
    return parse(Int, r)
end

export get_auto_start_state
"""
# show_auto_start_state(device::NHQ_Module, channel::Symbol)

Shows the state of the auto start option.
'channel' can be ':A' or ':B' (channel 1 or 2).
"""
function show_auto_start_state(device::NHQ_Module, channel::Symbol)
    value = get_auto_start_state(device, channel)
    if value == 0
        println("OFF: Auto start is inactive.")
    elseif value == 8
        println("On: Auto start is active.")
    else
        error("Unknown auto start state: $value")
    end
end

export show_auto_start_state
"""
# get_module_status(device::NHQ_Module, channel::Symbol)

Reads out the module state of the device.
'channel' can be ':A' or ':B' (channel 1 or 2).
"""
function get_module_status(device::NHQ_Module, channel::Symbol)
    chn = get_channel(channel)
    r = query(device, "T$chn")
    return parse(UInt8, r)
end
"""
# show_module_status(device::NHQ_Module, channel::Symbol)

Shows the module state of the device.
'channel' can be ':A' or ':B' (channel 1 or 2).
"""
function show_module_status(device::NHQ_Module, channel::Symbol)
    b = bits(get_module_status(device, channel))
    if (b[1] == 1) println("QUA: Quality of output voltage not given at present") end
    if (b[2] == 1) println("ERR: Maximum voltage or current was exceeded") end
    if (b[3] == 1)
        println("INH: INHIBIT signal was/is active")
    else
        println("INH: INHIBIT signal was/is inactive")
    end
    if (b[4] == 1)
        println("KILL_ENA: Kill enabled is on")
    else
        println("KILL_ENA: Kill enabled is off")
    end
    if (b[5] == 1)
        println("OFF: Front panel HV-ON switch in OFF position")
    else
        println("OFF: Front panel HV-ON switch in ON position")
    end
    if (b[6] == 1)
        println("POL: Polarity set to positive")
    else
        println("POL: Polarity set to negative")
    end
    if (b[7] == 1)
        println("MAN: Control: manual")
    else
        println("MAN: Control: via RS-232 interface")
    end
    nothing
end
export show_module_status
end # module
