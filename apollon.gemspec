require 'time'

Gem::Specification.new do |s|
  s.name        = 'apollon'
  s.version     = '0.0.1'
  s.date        = Time.now.strftime('%Y-%m-%d')
  s.summary     = "iOS Staticization Solution"
  s.authors     = ["shayanbo"]
  s.email       = 'yanbo.sha@gmail.com'
  s.files       = ["lib/apollon.rb"]
  s.homepage    = 'http://rubygems.org/gems/apollon'
  s.license     = 'MIT'
  s.post_install_message = """
  █████╗  ██████╗   ██████╗  ██╗      ██╗       ██████╗  ███╗   ██╗
 ██╔══██╗ ██╔══██╗ ██╔═══██╗ ██║      ██║      ██╔═══██╗ ████╗  ██║
 ███████║ ██████╔╝ ██║   ██║ ██║      ██║      ██║   ██║ ██╔██╗ ██║
 ██╔══██║ ██╔═══╝  ██║   ██║ ██║      ██║      ██║   ██║ ██║╚██╗██║
 ██║  ██║ ██║      ╚██████╔╝ ███████╗ ███████╗ ╚██████╔╝ ██║ ╚████║
 ╚═╝  ╚═╝ ╚═╝       ╚═════╝  ╚══════╝ ╚══════╝  ╚═════╝  ╚═╝  ╚═══╝
  """
  s.bindir      = 'bin'
  s.executables = 'apollon'
  s.required_ruby_version = '>= 2.4.1'
  s.add_runtime_dependency 'cocoapods', '>= 1.5.3'
end
