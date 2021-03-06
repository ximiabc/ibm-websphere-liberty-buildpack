# Encoding: utf-8
# IBM WebSphere Application Server Liberty Buildpack
# Copyright 2014 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License

require 'liberty_buildpack/diagnostics/logger_factory'
require 'liberty_buildpack/repository/configured_item'
require 'liberty_buildpack/repository/repository_utils'

module LibertyBuildpack::Services

  #-----------------------------------
  # A class of static utility methods
  #-----------------------------------
  class Utils

    #---------------------------------------------------------------------
    # A utility method that can be used by most service classes to generate runtime-vars.xml entries. Services with json that does not follow normal conventions
    # might not be able to use this utility method and should provide the proper implementation in the service class. For services with json with non-String values
    # it is possible to customize how the property values are converted into a String by provding a code block that does the translation. For example:
    #
    #  Utils.parse_compliant_vcap_service(doc.root, vcap_services) do | name, value |
    #    if name == 'credentials.scope'
    #      value = value.join(' ')
    #    else
    #      value
    #    end
    #  end
    #
    # By default, properties of Array type are converted into a comma separated String.
    #
    # @param [REXML::Element] element - the root element for the runtime-vars.xml doc. A new sub-element will be written to this doc for each cloud variable generated.
    # @param [Hash] properties - the vcap_services data for the service instance.
    # return a hash of cloud variables that mirrors what was written to runtime-vars.xml for use in the service implementation, as appropriate.
    #-----------------------------------------------------------------------
    def self.parse_compliant_vcap_service(element, properties)
      hash_to_return = {}
      properties.keys.each do |property|
        if properties[property].class == String
          # base attribute. Create cloud form of variable and add to runtime_vars and hash.
          # To make life easier for the user, add a special key into the return hash to make it easier to find the name of the service.
          hash_to_return['service_name'] = properties[property] if property == 'name'
          name = "cloud.services.#{properties['name']}.#{property}"
          value = block_given? ? yield(property, properties[property]) : properties[property]
          add_runtime_var(element, hash_to_return, name, value)
        elsif properties[property].class == Hash && property == 'credentials'
          # credentials. Create cloud form of variable and add to runtime_vars and hash
          properties[property].keys.each do |subproperty|
            name = "cloud.services.#{properties['name']}.connection.#{subproperty}"
            value = properties[property][subproperty]
            if block_given?
              value = yield("#{property}.#{subproperty}", value)
            elsif value.is_a?(Array)
              value = value.join(', ')
            end
            add_runtime_var(element, hash_to_return, name, value)
          end # each subproperty
        end
      end
      hash_to_return
    end

    #------------------------------------------------------------------------------------
    # a method to get a cloud property substitution variable.
    #
    # @param [Hash] properties - the hash of cloud variables generated by the Utils.parse_compliant_vcap_service method.
    # @param [String] service_name - the name of the calling service, for debug purposes.
    # @param [String] prop_name - the basic property name, in cloud form. Something like cloud.service.*.port, cloud.service.*.host,, etc
    # @param [String] prop_name_alias - the alias if the property has one (e.g. host and hostname are considered aliases.)
    # return the ant-style cloud variable.
    # @raise if the property does not exist in properties.
    #------------------------------------------------------------------------------------
    def self.get_cloud_property(properties, service_name, prop_name, prop_name_alias = nil)
      return "${#{prop_name}}" if properties.key?(prop_name)
      return "${#{prop_name_alias}}" if prop_name_alias.nil? == false && properties.key?(prop_name_alias)
      raise "Resource #{service_name} does not contain a #{prop_name} property"
    end

    #------------------------------------------------------------------------------------
    # A utility method to to add features into the server.xml featureManager. The features
    # parameter can be specified as an array, for example ['jdbc-4.0'] or as a hash. If the
    # parameter is specified as a hash value, it must contain 'if', 'then', and 'else' mappings.
    # The function will check if any of the features specified under the 'if' mapping exist in
    # the server.xml. If a single match is found, the function will add the features under the
    # 'then' mapping into the featureManager. Otherwise, the features under the 'else' mapping
    # will be added.
    #
    # @param [REXML::Element] doc - the root element of the server.xml document.
    # @param features - an array or hash of features to add to the featureManager.
    #------------------------------------------------------------------------------------
    def self.add_features(doc, features)
      raise 'invalid parameters' if doc.nil? || features.nil?

      current_features = get_features(doc)
      if features.is_a?(Hash)
        condition_features = features['if']
        condition_true_features = features['then']
        condition_false_features = features['else']
        raise 'Invalid feature condition' if condition_features.nil? || condition_true_features.nil? || condition_false_features.nil?

        if shared_elements?(current_features, condition_features)
          add_features_sub(doc, current_features, condition_true_features)
        else
          add_features_sub(doc, current_features, condition_false_features)
        end
      elsif features.is_a?(Array)
        add_features_sub(doc, current_features, features)
      else
        raise 'Invalid feature expression type'
      end
    end

    #----------------------------------------------------------------------------------------
    # A Utility method that ensures bootstrap.properties exists in the server directory and contains specified property
    #
    # @param [String] server_dir - the name of the server dir.
    # @param [String] property - The property, e.g. 'websphere.log.provider=binaryLogging-1.0'
    # @param [Regexp] reg_ex - The Regexp used to search an existing bootstrap.properties for a property, e.g. /websphere.log.provider[\s]*=[\s]*binaryLogging-1.0/
    #---------------------------------------------------------------------------------------
    def self.update_bootstrap_properties(server_dir, property, reg_ex)
      raise 'invalid parameters' if server_dir.nil? || property.nil? || reg_ex.nil?
      bootstrap = File.join(server_dir, 'bootstrap.properties')
      if File.exist?(bootstrap) == false
        File.open(bootstrap, 'w')  { |file| file.write(property) }
      else
        bootstrap_contents = File.readlines(bootstrap)
        bootstrap_contents.each do |line|
          return if (line =~ reg_ex).nil? == false
        end
        File.open(bootstrap, 'a') { |file| file.write(property) }
      end
    end

    #-------------------------------------------------
    # Return true if the specified array contains a single logical configuration element. A logical Element may be partitioned over multiple
    # physical Elements with the same configuration id
    #
    # @param [Array<REXML::Element>] elements_array - The non-null array containing the elements to check.
    # @ return true if the array describes a single logical element, false otherwise
    #-------------------------------------------------
    def self.logical_singleton?(elements_array)
      return true if elements_array.length == 1
      id = elements_array[0].attribute('id')
      elements_array[1..(elements_array.length - 1)].each do |element|
        my_id = element.attribute('id')
        return false if my_id != id
      end
      true
    end

    #------------------------------------------------------------------------------------
    # Utility method that searches an Element array that defines a single logical configuration stanza for the named attribute and
    # updates it to the specified value.
    # - if multiple instances of the attribute are found, all are updated. (User error in the provided xml)
    # - if the attribute is not found, then add it to an arbitrary element.
    #
    # @param [ARRAY<REXML::Element>] element_array - the non-null Element array
    # @param [String] name - the non-null attribute name.
    # @param [String] value - the value.
    #------------------------------------------------------------------------------------
    def self.find_and_update_attribute(element_array, name, value)
      found = false
      element_array.each do |element|
        # Liberty allows the logical stanza to be partitioned over multiple physical stanzas. Well-formed xml will declare a given attribute once, at most.
        # We handle xml that is not well formed by searching all partitions and updating all instances, to ensure the value is applied.
        unless element.attribute(name).nil?
          element.add_attribute(name, value)
          found = true
        end
      end
      # Attribute was not found, add it. Add it to last element.
      element_array[-1].add_attribute(name, value) unless found
    end

    #------------------------------------------------------------------------------------
    # Utility method that searches an Element array that defines a single logical Element for the named attribute and returns the last value.
    # If the attribute is defined multiple times, the value of the last instance is returned.
    #
    # @param [ARRAY<REXML::Element>] element_array - the non-null Element array
    # @param [String] name - the non-null attribute name.
    #------------------------------------------------------------------------------------
    def self.find_attribute(element_array, name)
      retval = nil
      element_array.each do |element|
        if element.attribute(name).nil? == false
          retval = element.attribute(name).value
        end
      end
      retval
    end

    #---------------------------------------------------
    # A utility method that returns an array of all application/webApplication Elements
    #
    # @param [REXML::Element] doc - the root Element of the server.xml document.
    #---------------------------------------------------
    def self.get_applications(doc)
      applications = []
      apps = doc.elements.to_a('//application')
      apps.each { |app| applications.push(app) }
      webapps = doc.elements.to_a('//webApplication')
      webapps.each { |webapp| applications.push(webapp) }
      applications
    end

    #-------------------------------
    # Return the api visibility setting from the classloader for the single configured application. Nil is returned if there is not exactly one app configured, if the one app does
    # not configure a classloader, or if the api visibility is not set.
    #
    # @param [REXML::Element] doc - the root Element of the server.xml document.
    #-------------------------------
    def self.get_api_visibility(doc)
      apps = Utils.get_applications(doc)
      unless apps.length == 1
        LibertyBuildpack::Diagnostics::LoggerFactory.get_logger.warn("Unable to determine classloader visibility as there are #{apps.length} apps")
        return
      end
      classloaders = apps[0].get_elements('classloader')
      return nil if classloaders.empty?
      # At present, Liberty only supports one classloader per app, but that may change. Visibility may only be specified on one classloader, if multiples exist.
      classloaders.each do |classloader|
        return classloader.attribute('apiTypeVisibility').value if classloader.attribute('apiTypeVisibility').nil? == false
      end
      nil
    end

    #------------------------------------------------------------------------------------
    # A Utility method to add a library to the single application. The method silently returns if there is not exactly one application.
    # The classloader will be created if the one application does not already contain a classloader element.
    #
    # @param [REXML::Element] doc - the root Element of the server.xml doc.
    # @param [String] debug_name - the non-null name of the calling service, used for serviceability.
    # @param [String] lib_id - the non-null id for the shared library
    #------------------------------------------------------------------------------------
    def self.add_library_to_app_classloader(doc, debug_name, lib_id)
      # Get a list of all applications. If there is more than one application, we do not know which application to add the library to.
      apps = Utils.get_applications(doc)
      unless apps.length == 1
        LibertyBuildpack::Diagnostics::LoggerFactory.get_logger.warn("Unable to add a shared library for service #{debug_name}. There are #{apps.length} applications")
        return
      end
      classloaders = apps[0].get_elements('classloader')
      # At present, Liberty only allows a single classloader element per application However, assume this may change in the future, handle partitioned classloader.
      if classloaders.empty?
        classloader_element = REXML::Element.new('classloader', apps[0])
        classloader_element.add_attribute('commonLibraryRef', lib_id)
        return
      end
      classloaders.each do |classloader|
        next if classloader.attribute('commonLibraryRef').nil?
        # commonLibraryRef contain a comma-separated string of library ids.
        cur_value = classloader.attribute('commonLibraryRef').value
        return if cur_value.include?(lib_id)
        classloader.add_attribute('commonLibraryRef', "#{cur_value},#{lib_id}")
        return
      end
      classloaders[0].add_attribute('commonLibraryRef', lib_id)
    end

    private

    #-------------------------------------------
    # Add a runtime var to runtime-vars.xml. A new Element named 'variable' will be added to the runtime-vars doc and the new Element will have an attribute of name, value
    #
    # @param [REXML::Element] element - the root element of runtime-vars.xml
    # @param [Hash] instance_hash - a hash passed in by the user to which the name-value pair is added.
    # @param [String] name - the non-null name of the attribute to add
    # @param [String] value - the non-null value of the attribute
    #---------------------------------------------
    def self.add_runtime_var(element, instance_hash, name, value)
      new_element = REXML::Element.new('variable', element)
      new_element.add_attribute('name', name)
      new_element.add_attribute('value', value)
      instance_hash[name] = value
    end

    #----------------------------------------------------------------------------------------
    # Determine which client jars need to be downloaded for this service to function properly.
    # Look up the client jars based on the 'client_jar_key', 'client_jar_url', or 'driver' information in the plugin configuration.
    #
    # @param config - plugin configuration.
    # @param urls - an array containing the available download urls for client jars
    # return - a non-null array of urls. Will be empty if nothing needs to be downloaded.
    #-----------------------------------------------------------------------------------------
    def self.get_urls_for_client_jars(config, urls)
      logger = LibertyBuildpack::Diagnostics::LoggerFactory.get_logger
      client_jar_key = config['client_jar_key']
      if client_jar_key.nil? || urls[client_jar_key].nil?
        # client_jar_key not found - check for client_jar_url
        client_jar_url = config['client_jar_url']
        if client_jar_url.nil?
          # client_jar_url not found - check for driver
          repository = config['driver']
          if repository.nil?
            # driver not found
            logger.debug('No client_jar_key, client_jar_url, or driver defined.')
            return []
          else
            # driver found
            version, driver_uri = LibertyBuildpack::Repository::ConfiguredItem.find_item(repository)
            logger.debug("Found driver: version: #{version}, url: #{driver_uri}")
            return [driver_uri]
          end
        else
          # client_jar_url found
          logger.debug("Found client_jar_url: #{client_jar_url}")
          utils = LibertyBuildpack::Repository::RepositoryUtils.new
          return [utils.resolve_uri(client_jar_url)]
        end
      else
        # client_jar_key found
        logger.debug("Found client_jar_key: #{urls[client_jar_key]}")
        return [urls[client_jar_key]]
      end
    end

    def self.get_features(doc)
      managers = doc.elements.to_a('//featureManager')
      features = Set.new
      managers.each do |manager|
        elements = manager.get_elements('feature')
        elements.each do |element|
          features.add(element.text)
        end
      end
      features
    end

    def self.add_features_sub(doc, current_features, features)
      additional_features = Set.new
      features.each do |feature|
        additional_features.add(feature) unless current_features.include?(feature)
      end

      managers = doc.elements.to_a('//featureManager')
      if managers.empty?
        manager = REXML::Element.new('featureManager', doc.root)
      else
        manager = managers.first
      end
      additional_features.each do |feature|
        element = REXML::Element.new('feature', manager)
        element.add_text(feature)
      end
    end

    def self.shared_elements?(array1, array2)
      array2.each do |element|
        return true if array1.include?(element)
      end
      false
    end

  end

end
