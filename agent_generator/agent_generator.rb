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
  end

  def getPackageName()
    return @packageName
  end

  def getAgentName()
    return @agentName
  end

  def getParameters()
    ## result have to be array as order should be preserved
    params = Array.new

    @doc.elements.each("resource-agent/parameters/parameter") { |p|
      param = Hash.new
      param["name"] = REXML::XPath.match(p, "string(./@name)")[0]
      param["type"] = REXML::XPath.match(p, "string(./content/@type)")[0]
      ## if 'default' is list then we can not enter it as parameter !!
      ## this is problem only for 'cmd_prompt'
      param["default"] = REXML::XPath.match(p, "string(./content/@default)")[0]

      ## remove parameters that are not usable during automatic execution
      if not ["help", "version", "action"].include?(param["name"])
        params.push(param)
      end
    }
    return params
  end
end

class ManifestGenerator
  def initialize(parser)
    @parser = parser
  end

  def generate
    puts <<-eos
class pacemaker::stonith::#{@parser.getAgentName} (
#{getManifestParameters}
) {
  $real_address = "$(corosync-cfgtool -a $(crm_node -n))"

  if($ensure == absent) {
    exec {
      "Removing stonith::#{@parser.getAgentName}":
      command => "/usr/sbin/pcs stonith delete stonith-#{@parser.getAgentName}-${real_address}",
      onlyif => "/usr/sbin/pcs stonith show stonith-#{@parser.getAgentName}-${real_address} > /dev/null 2>&1",
      require => Class["pacemaker::corosync"],
    }
  } else {
  #{getVariableValues}
    $pcmk_host_value_chunk = $pcmk_host_list ? {
      '' => '$(/usr/sbin/crm_node -n)',
      default => "${pcmk_host_list}",
    }

    package {
      "#{@parser.getPackageName}": ensure => installed,
    } -> exec {
      "Creating stonith::#{@parser.getAgentName}":
      command => "/usr/sbin/pcs stonith create stonith-#{@parser.getAgentName}-${real_address} #{@parser.getAgentName} pcmk_host_list=\\"${pcmk_host_value_chunk}\\" #{getChunks} op monitor interval=${interval}",
      unless => "/usr/sbin/pcs stonith show stonith-#{@parser.getAgentName}-${real_address} > /dev/null 2>&1",
      require => Class["pacemaker::corosync"],
    } -> exec {
      "Adding non-local constraint stonith::#{@parser.getAgentName} ${real_address}":
      command => "/usr/sbin/pcs constraint location stonith-#{@parser.getAgentName}-${real_address} avoids ${pcmk_host_value_chunk}"
    }
  }
}
eos
  end

  def getManifestParameters
    text = ""
    @parser.getParameters.each { |p|
      text += "\t$#{p['name']} = undef,\n"
    }

    text += "\n"
    text += "\t$interval = \"60s\",\n"
    text += "\t$ensure = present,\n"
    text += "\t$pcmk_host_value = undef,\n"

    return text
  end

  def getVariableValues
    text = ""
    @parser.getParameters.each { |p|
      text += "\t$#{p['name']}_chunk = $#{p['name']} ? {\n"
      text += "\t\tundef => \"\",\n"
      text += "\t\tdefault => \"#{p['name']}=\\\"${#{p['name']}}\\\"\",\n"
      text += "\t}\n"
    }

    return text
  end

  def getChunks
    text = ""
    @parser.getParameters.each { |p|
      text += "${#{p['name']}_chunk} "
    }
    return text
  end
end

if ARGV.length != 3 then
  puts "You have to enter three arguments: path to metadata, name of fence agent and fence agent package"
  exit 1
end

metadata, agentName, packageName = ARGV
# e.g. parser = FencingMetadataParser.new("ilo.xml", "fence_ilo", "fence-agents-ilo2")
parser = FencingMetadataParser.new(metadata, agentName, packageName)
ManifestGenerator.new(parser).generate
