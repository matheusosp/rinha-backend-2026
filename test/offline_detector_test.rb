$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'json'
require 'detector'

detector = Detector.new(data_dir: ENV.fetch('DATA_DIR', 'data'))
entries = JSON.parse(File.read(File.expand_path('test-data.json', __dir__))).fetch('entries')

fp = 0
fn = 0

entries.each do |entry|
  approved, = detector.score(entry.fetch('request'))
  expected = entry.fetch('expected_approved')

  next if approved == expected

  if approved
    fn += 1
  else
    fp += 1
  end
end

weighted_errors = fp + (3 * fn)
epsilon = weighted_errors.to_f / entries.length
detection_score =
  1000.0 * Math.log10(1.0 / [epsilon, 0.001].max) -
  300.0 * Math.log10(1 + weighted_errors)

puts "FP=#{fp} FN=#{fn} E=#{weighted_errors} detection_score=#{detection_score.round(2)}"

abort 'detection_score target not met' unless detection_score > 2000.0
