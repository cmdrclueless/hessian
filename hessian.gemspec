# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require 'hessian'

Gem::Specification.new do |s|
  s.name        = "hessian"
  s.version     = Hessian::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ['Christer Sandberg', 'Trent Albright', 'Brian Weaver']
  s.email       = ['chrsan@gmail.com', 'trent.albright@gmail.com', 'cmdrclueless@gmail.com']
  s.homepage    = 'https://github.com/cmdrclueless/hessian'
  s.summary     = %q{Hessian Ruby Module}
  s.description = %q{Hessian Ruby client library}

  s.files       = Dir['lib/**/*'] + %w{Rakefile README.markdown LICENSE}
end
