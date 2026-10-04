param(
    [Parameter(Mandatory=$true)]
    [string]$TargetHost,

    [Parameter(Mandatory=$false)]
    [int]$TargetPort = 25565,

    [Parameter(Mandatory=$false)]
    [int]$ListenPort = 25565
)

$ErrorActionPreference = "Stop"

function Read-VarInt {
    param([System.IO.Stream]$Stream)

    $numRead = 0
    $result = 0

    while ($true) {
        $byte = $Stream.ReadByte()

        if ($byte -eq -1) {
            throw "Connection closed while reading VarInt."
        }

        $value = $byte -band 0x7F
        $result = $result -bor ($value -shl (7 * $numRead))

        $numRead++

        if (($byte -band 0x80) -eq 0) {
            break
        }

        if ($numRead -ge 5) {
            throw "Invalid VarInt."
        }
    }

    return $result
}

function Write-VarInt {
    param(
        [System.IO.Stream]$Stream,
        [int]$Value
    )

    while ($true) {

        if (($Value -band 0xFFFFFF80) -eq 0) {
            $Stream.WriteByte([byte]$Value)
            break
        }

        $Stream.WriteByte(
            [byte](($Value -band 0x7F) -bor 0x80)
        )

        $Value = $Value -shr 7
    }
}

function Encode-VarInt {
    param([int]$Value)

    $bytes = New-Object System.Collections.Generic.List[byte]

    while ($true) {

        if (($Value -band 0xFFFFFF80) -eq 0) {
            [void]$bytes.Add([byte]$Value)
            break
        }

        [void]$bytes.Add(
            [byte](($Value -band 0x7F) -bor 0x80)
        )

        $Value = $Value -shr 7
    }

    return [byte[]]$bytes.ToArray()
}

function Read-Exactly {
    param(
        [System.IO.Stream]$Stream,
        [int]$Length
    )

    $buffer = New-Object byte[] $Length
    $offset = 0

    while ($offset -lt $Length) {

        $read = $Stream.Read(
            $buffer,
            $offset,
            $Length - $offset
        )

        if ($read -le 0) {
            throw "Connection closed while reading packet."
        }

        $offset += $read
    }

    return $buffer
}

function Read-MinecraftString {
    param(
        [System.IO.Stream]$Stream
    )

    $length = Read-VarInt $Stream

    if ($length -lt 0 -or $length -gt 32767) {
        throw "Invalid Minecraft string length: $length"
    }

    $bytes = Read-Exactly $Stream $length

    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Encode-MinecraftString {
    param(
        [string]$Value
    )

    $stringBytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $lengthBytes = Encode-VarInt $stringBytes.Length

    $result = New-Object System.Collections.Generic.List[byte]

    $result.AddRange([byte[]]$lengthBytes)
    $result.AddRange([byte[]]$stringBytes)

    return [byte[]]$result.ToArray()
}

Write-Host "=========================================="
Write-Host " Minecraft TCP Proxy"
Write-Host "=========================================="
Write-Host "Listen : 0.0.0.0:$ListenPort"
Write-Host "Target : $TargetHost`:$TargetPort"
Write-Host "=========================================="

$listener = [System.Net.Sockets.TcpListener]::new(
    [System.Net.IPAddress]::Any,
    $ListenPort
)

$listener.Start()

Write-Host "Proxy is listening."

try {

    while ($true) {

        $client = $null
        $target = $null

        try {

            $client = $listener.AcceptTcpClient()
            $client.NoDelay = $true

            Write-Host ""
            Write-Host "[$(Get-Date)] Client connected: $($client.Client.RemoteEndPoint)"

            $clientStream = $client.GetStream()

            #
            # Read first Minecraft packet
            #

            $packetLength = Read-VarInt $clientStream

            if ($packetLength -le 0 -or $packetLength -gt 2097152) {
                throw "Invalid packet length: $packetLength"
            }

            $packet = Read-Exactly $clientStream $packetLength

            #
            # Parse Minecraft Handshake
            #

            $ms = New-Object System.IO.MemoryStream(,$packet)

            $packetId = Read-VarInt $ms

            if ($packetId -ne 0) {
                throw "First packet is not a Minecraft Handshake. Packet ID: $packetId"
            }

            $protocolVersion = Read-VarInt $ms
            $hostname = Read-MinecraftString $ms

            $portBytes = Read-Exactly $ms 2

            $serverPort =
                ($portBytes[0] -shl 8) -bor
                $portBytes[1]

            $nextState = Read-VarInt $ms

            Write-Host "Minecraft protocol : $protocolVersion"
            Write-Host "Original hostname  : $hostname"
            Write-Host "Original port      : $serverPort"
            Write-Host "Next state         : $nextState"

            #
            # Build new handshake
            #

            $newHostname = $TargetHost

            Write-Host "Proxy hostname     : $newHostname"

            $handshakeBody = New-Object System.Collections.Generic.List[byte]

            # Packet ID
            $packetIdBytes = Encode-VarInt 0
            $handshakeBody.AddRange([byte[]]$packetIdBytes)

            # Protocol version
            $protocolBytes = Encode-VarInt $protocolVersion
            $handshakeBody.AddRange([byte[]]$protocolBytes)

            # Hostname
            $hostnameBytes = Encode-MinecraftString $newHostname
            $handshakeBody.AddRange([byte[]]$hostnameBytes)

            # Server port
            $handshakeBody.AddRange([byte[]]$portBytes)

            # Next state
            $stateBytes = Encode-VarInt $nextState
            $handshakeBody.AddRange([byte[]]$stateBytes)

            $newPacket = [byte[]]$handshakeBody.ToArray()

            #
            # Connect to target
            #

            $target = [System.Net.Sockets.TcpClient]::new()
            $target.NoDelay = $true

            $target.Connect(
                $TargetHost,
                $TargetPort
            )

            Write-Host "Connected to target: $TargetHost`:$TargetPort"

            $targetStream = $target.GetStream()

            #
            # Send modified handshake
            #

            Write-VarInt $targetStream $newPacket.Length

            $targetStream.Write(
                $newPacket,
                0,
                $newPacket.Length
            )

            #
            # Forward remaining traffic
            #

            $clientToTarget =
                $clientStream.CopyToAsync($targetStream)

            $targetToClient =
                $targetStream.CopyToAsync($clientStream)

            [System.Threading.Tasks.Task]::WaitAny(
                @(
                    $clientToTarget,
                    $targetToClient
                )
            ) | Out-Null

        }
        catch {

            Write-Host ""
            Write-Host "ERROR: $($_.Exception.Message)"
        }
        finally {

            if ($target) {
                try {
                    $target.Close()
                }
                catch {}
            }

            if ($client) {
                try {
                    $client.Close()
                }
                catch {}
            }

            Write-Host "[$(Get-Date)] Client disconnected."
        }
    }

}
finally {

    $listener.Stop()
}
