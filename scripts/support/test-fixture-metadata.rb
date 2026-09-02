#!/usr/bin/ruby

require 'open3'

# Availability only: production still rejects every xattr, including provenance.
def classify_fixture_metadata(names, size)
  return 'clean' if names.empty? && size.empty?
  return 'persistent-provenance' if names == 'com.apple.provenance' && size == '11'

  abort('fixture metadata: unexpected attributes or sizes')
end

def run(*command)
  output, errors, result = Open3.capture3({ 'LC_ALL' => 'C' }, *command)
  abort('fixture metadata: inspection failed') unless result.success? && errors.empty?
  output
end

def inspect_fixture_metadata(owned_root, target)
  abort('fixture metadata: symlink owner') if File.lstat(owned_root).symlink?
  owned_root = File.realpath(owned_root)
  abort('fixture metadata: invalid owner') unless File.directory?(owned_root) && owned_root != '/'
  # Resolve parents, not the leaf: an owned symlink's metadata is safe to inspect.
  target = File.expand_path(target)
  target = File.join(File.realpath(File.dirname(target)), File.basename(target))
  unless target == owned_root || target.start_with?("#{owned_root}/")
    abort('fixture metadata: outside owned root')
  end

  state = 'clean'
  visit = lambda do |entry|
    metadata = File.lstat(entry)
    unless metadata.directory? || metadata.file? || metadata.symlink?
      abort('fixture metadata: unsupported entry type')
    end
    names = run('/usr/bin/xattr', '-s', entry).chomp
    size = ''
    if names == 'com.apple.provenance'
      # ls -d never follows the leaf symlink; -@ reports sizes, not values.
      sizes = run('/bin/ls', '-ld@', entry).lines.map do |line|
        fields = line.split
        fields[1] if fields[0] == 'com.apple.provenance'
      end
      size = sizes.compact.join("\n")
    end
    observed = classify_fixture_metadata(names, size)
    state = observed unless observed == 'clean'
    if metadata.directory? && !metadata.symlink?
      Dir.children(entry).sort.each { |name| visit.call(File.join(entry, name)) }
    end
  end
  visit.call(target)
  state
end

begin
  abort('Usage: test-fixture-metadata.rb classify NAMES SIZE | inspect OWNED_ROOT TARGET') unless ARGV.length == 3
  case ARGV[0]
  when 'classify' then puts classify_fixture_metadata(ARGV[1], ARGV[2])
  when 'inspect' then puts inspect_fixture_metadata(ARGV[1], ARGV[2])
  else abort('fixture metadata: unknown command')
  end
rescue SystemCallError, IOError
  abort('fixture metadata: inspection failed')
end
