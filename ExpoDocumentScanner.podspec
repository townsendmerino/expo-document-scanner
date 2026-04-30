require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name           = 'ExpoDocumentScanner'
  s.version        = package['version']
  s.summary        = package['description']
  s.author         = { 'Francis Townsend-Merino' => 'townsendmerino@gmail.com' }
  s.homepage       = 'https://github.com/townsendmerino/expo-document-scanner'
  s.license        = { :type => 'MIT', :file => 'LICENSE' }
  s.platforms      = { :ios => '15.0' }
  s.swift_version  = '5.4'
  s.source         = { :git => 'https://github.com/townsendmerino/expo-document-scanner.git', :tag => s.version.to_s }
  s.dependency 'ExpoModulesCore'

  s.source_files = 'ios/**/*.{h,m,mm,swift}'
end
