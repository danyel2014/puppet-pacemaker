#!/usr/bin/ruby

# Usage:
#
# * install a fence agent package e.g. fence-agents-ilo2
# * fence_ilo2 -o metadata > ilo.xml
# * fence-generator.rb ilo.xml fence_ilo2 fence-agents-ilo2
#      [ XML metadata, name of the class, name of the package for dependency check ]

require 'rexml/document'

class FencingMetadataParser
  def initialize(filename, agentName, packageName)
    @agentName = agentName
    @packageName = packageName
    file = File.new(filename)
    @doc = REXML::Document.new file
    @params = []
    @params_max_len = 14 # pcmk_host_list
  end

  def getPackageName
    @packageName
  end

  def getAgentName
    @agentName
  end

  def getParameters
    ## result have to be array as order should be preserved
    return @params unless @params.empty?
    @doc.elements.each('resource-agent/parameters/parameter') { |p|
      param = {}
      param['name'] = REXML::XPath.match(p, 'string(./@name)')[0]
      @params_max_len = param['name'].length if param['name'].length > @params_max_len
      param['type'] = REXML::XPath.match(p, 'string(./content/@type)')[0]
      ## if 'default' is list then we can not enter it as parameter !!
      ## this is problem only for 'cmd_prompt'
      param['default'] = REXML::XPath.match(p, 'string(./content/@default)')[0]
      param['description'] = REXML::XPath.match(p, 'string(./shortdesc)')[0]
      ## remove parameters that are not usable during automatic execution
      @params.push(param) unless %w(help version).include?(param['name'])
    }
    @params
  end

  def getMaxLen
    @params_max_len
  end
end

class ManifestGenerator
  def initialize(parser)
    @parser = parser
  end

  def generate
    puts <<-eos
# == Define: pacemaker::stonith::#{@parser.getAgentName}
#
# Module for managing Stonith for #{@parser.getAgentName}.
#
# WARNING: Generated by "rake generate_stonith", manual changes will
# be lost.
#
# === Parameters
#
#{getManifestDocumentation}#  [*interval*]
#   Interval between tries.
#
# [*ensure*]
#   The desired state of the resource.
#
# [*tries*]
#   The number of tries.
#
# [*try_sleep*]
#   Time to sleep between tries.
#
# [*pcmk_host_list*]
#   List of Pacemaker hosts.
#
# === Dependencies
#  None
#
# === Authors
#
# Generated by rake generate_stonith task.
#
# === Copyright
#
# Copyright (C) 2016 Red Hat Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
#
define pacemaker::stonith::#{@parser.getAgentName} (
#{getManifestParameters}
) {
#{getVariableValues}
  $pcmk_host_value_chunk = $pcmk_host_list ? {
    undef   => '$(/usr/sbin/crm_node -n)',
    default => $pcmk_host_list,
  }

  # $title can be a mac address, remove the colons for pcmk resource name
  $safe_title = regsubst($title, ':', '', 'G')

  # On Pacemaker Remote nodes we don't want a full corosync
  $pcmk_require = str2bool($::pcmk_is_remote) ? { true => [], false => Class['pacemaker::corosync'] }

  $param_string = "#{getChunks} op monitor interval=${interval}"

  if $ensure != 'absent' {
    package { '#{@parser.getPackageName}':
      ensure => installed,
    }
    Package['#{@parser.getPackageName}'] -> Pcmk_stonith["stonith-#{@parser.getAgentName}-${safe_title}"]
  }
  pcmk_stonith { "stonith-#{@parser.getAgentName}-${safe_title}":
    ensure           => $ensure,
    stonith_type     => '#{@parser.getAgentName}',
    pcmk_host_list   => $pcmk_host_value_chunk,
    pcs_param_string => $param_string,
    require          => $pcmk_require,
    tries            => $tries,
    try_sleep        => $try_sleep,
  }
}
eos
  end

  def getManifestDocumentation
    text = ''
    @parser.getParameters.each { |p|
      text += "# [*#{p['name']}*]\n"
      text += "#   #{p['description']}\n#\n"
    }
    text
  end

  def getManifestParameters
    text = ''
    @parser.getParameters.each { |p|
      text += format_param(p['name'])
    }

    text += "\n"
    text += format_param('interval', "'60s'")
    text += format_param('ensure', 'present')
    text += format_param('pcmk_host_list')
    text += "\n"
    text += format_param('tries')
    text += format_param('try_sleep')

    text
  end

  def getVariableValues
    text = ''
    @parser.getParameters.each { |p|
      text += "  $#{p['name']}_chunk = $#{p['name']} ? {\n"
      text += "    undef   => '',\n"
      text += "    default => \"#{p['name']}=\\\"${#{p['name']}}\\\"\",\n"
      text += "  }\n"
    }

    text
  end

  def getChunks
    text = ''
    @parser.getParameters.each { |p|
      text += "${#{p['name']}_chunk} "
    }
    text
  end

  private

  def format_param(param, value = 'undef')
    "  $%-#{@parser.getMaxLen}s = %s,\n" % [param, value]
  end
end

if ARGV.length != 3
  puts 'You have to enter three arguments: path to metadata, name of fence agent and fence agent package'
  exit 1
end

metadata, agentName, packageName = ARGV
# e.g. parser = FencingMetadataParser.new("ilo.xml", "fence_ilo", "fence-agents-ilo2")
parser = FencingMetadataParser.new(metadata, agentName, packageName)
ManifestGenerator.new(parser).generate
