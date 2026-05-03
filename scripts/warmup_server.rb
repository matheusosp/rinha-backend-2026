require 'socket'

port = Integer(ENV.fetch('PORT', '5000'))
server = TCPServer.new('0.0.0.0', port)

BUILDING_RESPONSE = [
  "HTTP/1.1 503 Service Unavailable",
  "Content-Type: application/json",
  "Content-Length: 26",
  "Connection: close",
  "",
  '{"status":"building_index"}'
].join("\r\n").freeze

$stdout.puts "[warmup_server] listening on #{port} (returns 503 while index builds)"
$stdout.flush

loop do
  begin
    client = server.accept_nonblock
    client.write(BUILDING_RESPONSE)
    client.close
  rescue IO::WaitReadable
    IO.select([server], nil, nil, 1)
    retry
  rescue => e
    $stderr.puts "[warmup_server] #{e.class}: #{e.message}"
  end
end
