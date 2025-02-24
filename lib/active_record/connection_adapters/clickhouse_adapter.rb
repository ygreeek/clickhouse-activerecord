# frozen_string_literal: true

require 'clickhouse-activerecord/arel/visitors/to_sql'
require 'clickhouse-activerecord/arel/table'
require 'clickhouse-activerecord/migration'
require 'active_record/connection_adapters/clickhouse/oid/array'
require 'active_record/connection_adapters/clickhouse/oid/date'
require 'active_record/connection_adapters/clickhouse/oid/date_time'
require 'active_record/connection_adapters/clickhouse/oid/big_integer'
require 'active_record/connection_adapters/clickhouse/schema_definitions'
require 'active_record/connection_adapters/clickhouse/schema_creation'
require 'active_record/connection_adapters/clickhouse/schema_statements'
require 'net/http'

module ActiveRecord
  class Base
    class << self
      # Establishes a connection to the database that's used by all Active Record objects
      def clickhouse_connection(config)
        config = config.symbolize_keys

        if config[:connection]
          connection = {
            connection: config[:connection]
          }
        else
          port = config[:port] || 8123
          connection = {
            host: config[:host] || 'localhost',
            port: port,
            ssl: config[:ssl].present? ? config[:ssl] : port == 443,
            sslca: config[:sslca],
            read_timeout: config[:read_timeout],
            write_timeout: config[:write_timeout],
          }
        end

        if config.key?(:database)
          database = config[:database]
        else
          raise ArgumentError, 'No database specified. Missing argument: database.'
        end

        ConnectionAdapters::ClickhouseAdapter.new(logger, connection, { user: config[:username], password: config[:password], database: database }.compact, config)
      end
    end
  end

  class Relation

    # Replace for only ClickhouseAdapter
    def reverse_order!
      orders = order_values.uniq
      orders.reject!(&:blank?)
      if self.connection.is_a?(ConnectionAdapters::ClickhouseAdapter) && orders.empty? && !primary_key
        self.order_values = %w(date created_at).select {|c| column_names.include?(c) }.map{|c| arel_attribute(c).desc }
      else
        self.order_values = reverse_sql_order(orders)
      end
      self
    end
  end

  module TypeCaster
    class Map
      def is_view
        if @klass.respond_to?(:is_view)
          @klass.is_view # rails 6.1
        else
          types.is_view # less than 6.1
        end
      end
    end
  end

  module ModelSchema
     module ClassMethods
      def is_view
        @is_view || false
      end
       # @param [Boolean] value
      def is_view=(value)
        @is_view = value
      end

      def arel_table # :nodoc:
        @arel_table ||= ClickhouseActiverecord::Arel::Table.new(table_name, type_caster: type_caster)
      end

    end
   end

  module ConnectionAdapters
    class ClickhouseColumn < Column

    end

    class ClickhouseAdapter < AbstractAdapter
      ADAPTER_NAME = 'Clickhouse'.freeze
      NATIVE_DATABASE_TYPES = {
        string: { name: 'String' },
        integer: { name: 'UInt32' },
        big_integer: { name: 'UInt64' },
        float: { name: 'Float32' },
        decimal: { name: 'Decimal' },
        datetime: { name: 'DateTime' },
        datetime64: { name: 'DateTime64' },
        date: { name: 'Date' },
        boolean: { name: 'UInt8' },
        uuid: { name: 'UUID' },

        enum8: { name: 'Enum8' },
        enum16: { name: 'Enum16' },

        int8:  { name: 'Int8' },
        int16: { name: 'Int16' },
        int32: { name: 'Int32' },
        int64:  { name: 'Int64' },
        int128: { name: 'Int128' },
        int256: { name: 'Int256' },

        uint8: { name: 'UInt8' },
        uint16: { name: 'UInt16' },
        uint32: { name: 'UInt32' },
        uint64: { name: 'UInt64' },
        # uint128: { name: 'UInt128' }, not yet implemented in clickhouse
        uint256: { name: 'UInt256' },
      }.freeze

      include Clickhouse::SchemaStatements

      # Initializes and connects a Clickhouse adapter.
      def initialize(logger, connection_parameters, config, full_config)
        super(nil, logger)
        @connection_parameters = connection_parameters
        @config = config
        @debug = full_config[:debug] || false
        @full_config = full_config

        @prepared_statements = false
        if ActiveRecord::version == Gem::Version.new('6.0.0')
          @prepared_statement_status = Concurrent::ThreadLocalVar.new(false)
        end

        connect
      end

      # Support SchemaMigration from v5.2.2 to v6+
      def schema_migration # :nodoc:
        ClickhouseActiverecord::SchemaMigration
      end

      def migrations_paths
        @full_config[:migrations_paths] || 'db/migrate_clickhouse'
      end

      def migration_context # :nodoc:
        ClickhouseActiverecord::MigrationContext.new(migrations_paths, schema_migration)
      end

      def arel_visitor # :nodoc:
        ClickhouseActiverecord::Arel::Visitors::ToSql.new(self)
      end

      def native_database_types #:nodoc:
        NATIVE_DATABASE_TYPES
      end

      def valid_type?(type)
        !native_database_types[type].nil?
      end

      def extract_limit(sql_type) # :nodoc:
        case sql_type
          when /(Nullable)?\(?String\)?/
            super('String')
          when /(Nullable)?\(?U?Int8\)?/
            1
          when /(Nullable)?\(?U?Int16\)?/
            2
          when /(Nullable)?\(?U?Int32\)?/
            nil
          when /(Nullable)?\(?U?Int64\)?/
            8
          else
            super
        end
      end

      def initialize_type_map(m) # :nodoc:
        super
        register_class_with_limit m, %r(String), Type::String
        register_class_with_limit m, 'Date',  Clickhouse::OID::Date
        register_class_with_limit m, 'DateTime',  Clickhouse::OID::DateTime

        register_class_with_limit m, %r(Int8), Type::Integer
        register_class_with_limit m, %r(Int16), Type::Integer
        register_class_with_limit m, %r(Int32), Type::Integer
        register_class_with_limit m, %r(Int64), Type::Integer
        register_class_with_limit m, %r(Int128), Type::Integer
        register_class_with_limit m, %r(Int256), Type::Integer

        register_class_with_limit m, %r(UInt8), Type::UnsignedInteger
        register_class_with_limit m, %r(UInt16), Type::UnsignedInteger
        register_class_with_limit m, %r(UInt32), Type::UnsignedInteger
        register_class_with_limit m, %r(UInt64), Type::UnsignedInteger
        #register_class_with_limit m, %r(UInt128), Type::UnsignedInteger #not implemnted in clickhouse
        register_class_with_limit m, %r(UInt256), Type::UnsignedInteger
        # register_class_with_limit m, %r(Array), Clickhouse::OID::Array
        m.register_type(%r(Array)) do |sql_type|
          Clickhouse::OID::Array.new(sql_type)
        end
      end

      # Quoting time without microseconds
      def quoted_date(value)
        if value.acts_like?(:time)
          zone_conversion_method = ActiveRecord::Base.default_timezone == :utc ? :getutc : :getlocal

          if value.respond_to?(zone_conversion_method)
            value = value.send(zone_conversion_method)
          end
        end

        value.to_s(:db)
      end

      def column_name_for_operation(operation, node) # :nodoc:
        if ActiveRecord::version >= Gem::Version.new('6')
          visitor.compile(node)
        else
          column_name_from_arel_node(node)
        end
      end

      # Executes insert +sql+ statement in the context of this connection using
      # +binds+ as the bind substitutes. +name+ is logged along with
      # the executed +sql+ statement.

      # SCHEMA STATEMENTS ========================================

      def primary_key(table_name) #:nodoc:
        pk = table_structure(table_name).first
        return 'id' if pk.present? && pk[0] == 'id'
        false
      end

      def create_schema_dumper(options) # :nodoc:
        ClickhouseActiverecord::SchemaDumper.create(self, options)
      end

      # @param [String] table
      # @return [String]
      def show_create_table(table)
        do_system_execute("SHOW CREATE TABLE `#{table}`")['data'].try(:first).try(:first).gsub(/[\n\s]+/m, ' ')
      end

      # Create a new ClickHouse database.
      def create_database(name)
        sql = apply_cluster "CREATE DATABASE #{quote_table_name(name)}"
        log_with_debug(sql, adapter_name) do
          res = @connection.post("/?#{@config.except(:database).to_param}", sql)
          process_response(res)
        end
      end

      def create_view(table_name, **options)
        options.merge!(view: true)
        options = apply_replica(table_name, options)
        td = create_table_definition(apply_cluster(table_name), **options)
        yield td if block_given?

        if options[:force]
          drop_table(table_name, options.merge(if_exists: true))
        end

        execute schema_creation.accept td
      end

      def create_table(table_name, **options, &block)
        options = apply_replica(table_name, options)
        td = create_table_definition(apply_cluster(table_name), **options)
        block.call td if block_given?

        if options[:force]
          drop_table(table_name, options.merge(if_exists: true))
        end

        execute schema_creation.accept td

        if options[:with_distributed]
          distributed_table_name = options.delete(:with_distributed)
          sharding_key = options.delete(:sharding_key) || 'rand()'
          raise 'Set a cluster' unless cluster

          distributed_options =
            "Distributed(#{cluster}, #{@config[:database]}, #{table_name}, #{sharding_key})"
          create_table(distributed_table_name, **options.merge(options: distributed_options), &block)
        end
      end

      # Drops a ClickHouse database.
      def drop_database(name) #:nodoc:
        sql = apply_cluster "DROP DATABASE IF EXISTS #{quote_table_name(name)}"
        log_with_debug(sql, adapter_name) do
          res = @connection.post("/?#{@config.except(:database).to_param}", sql)
          process_response(res)
        end
      end

      def rename_table(table_name, new_name)
        do_execute apply_cluster "RENAME TABLE #{quote_table_name(table_name)} TO #{quote_table_name(new_name)}"
      end

      def drop_table(table_name, options = {}) # :nodoc:
        do_execute apply_cluster "DROP TABLE#{' IF EXISTS' if options[:if_exists]} #{quote_table_name(table_name)}"

        if options[:with_distributed]
          distributed_table_name = options.delete(:with_distributed)
          drop_table(distributed_table_name, **options)
        end
      end

      def change_column(table_name, column_name, type, options = {})
        result = do_execute "ALTER TABLE #{quote_table_name(table_name)} #{change_column_for_alter(table_name, column_name, type, options)}"
        raise "Error parse json response: #{result}" if result.presence && !result.is_a?(Hash)
      end

      def change_column_null(table_name, column_name, null, default = nil)
        structure = table_structure(table_name).select{|v| v[0] == column_name.to_s}.first
        raise "Column #{column_name} not found in table #{table_name}" if structure.nil?
        change_column table_name, column_name, structure[1].gsub(/(Nullable\()?(.*?)\)?/, '\2'), {null: null, default: default}.compact
      end

      def change_column_default(table_name, column_name, default)
        change_column table_name, column_name, nil, {default: default}.compact
      end

      def cluster
        @full_config[:cluster_name]
      end

      def replica
        @full_config[:replica_name]
      end

      def use_default_replicated_merge_tree_params?
        database_engine_atomic? && @full_config[:use_default_replicated_merge_tree_params]
      end

      def use_replica?
        (replica || use_default_replicated_merge_tree_params?) && cluster
      end

      def replica_path(table)
        "/clickhouse/tables/#{cluster}/#{@config[:database]}.#{table}"
      end

      def database_engine_atomic?
        current_database_engine = "select engine from system.databases where name = '#{@config[:database]}'"
        res = ActiveRecord::Base.connection.select_one(current_database_engine)
        res['engine'] == 'Atomic' if res
      end

      def apply_cluster(sql)
        cluster ? "#{sql} ON CLUSTER #{cluster}" : sql
      end

      def supports_insert_on_duplicate_skip?
        true
      end

      def supports_insert_on_duplicate_update?
        true
      end

      def build_insert_sql(insert) # :nodoc:
        sql = +"INSERT #{insert.into} #{insert.values_list}"
        sql
      end

      protected

      def last_inserted_id(result)
        result
      end

      def change_column_for_alter(table_name, column_name, type, options = {})
        td = create_table_definition(table_name)
        cd = td.new_column_definition(column_name, type, options)
        schema_creation.accept(ChangeColumnDefinition.new(cd, column_name))
      end

      private

      def connect
        @connection = @connection_parameters[:connection] || Net::HTTP.start(@connection_parameters[:host], @connection_parameters[:port], use_ssl: @connection_parameters[:ssl], verify_mode: OpenSSL::SSL::VERIFY_NONE)

        @connection.ca_file = @connection_parameters[:ca_file] if @connection_parameters[:ca_file]
        @connection.read_timeout = @connection_parameters[:read_timeout] if @connection_parameters[:read_timeout]
        @connection.write_timeout = @connection_parameters[:write_timeout] if @connection_parameters[:write_timeout]

        @connection
      end

      def apply_replica(table, options)
        if use_replica? && options[:options]
          if options[:options].match(/^Replicated/)
            raise 'Do not try create Replicated table. It will be configured based on the *MergeTree engine.'
          end

          options[:options] = configure_replica(table, options[:options])
        end
        options
      end

      def configure_replica(table, options)
        match = options.match(/^(.*?MergeTree)(?:\(([^\)]*)\))?((?:.|\n)*)/)
        return options unless match

        if replica
          engine_params = ([replica_path(table), replica].map { |v| "'#{v}'" } + [match[2].presence]).compact.join(', ')
        end

        "Replicated#{match[1]}(#{engine_params})#{match[3]}"
      end
    end
  end
end
