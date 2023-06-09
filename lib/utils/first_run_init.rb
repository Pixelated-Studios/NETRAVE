# frozen_string_literal: true

require 'curses'
require 'dynamic_curses_input'
require 'dotenv'
require_relative 'database_manager'
require_relative 'system_information_gather'
require_relative 'utilities'
require_relative 'alert_manager'
require_relative 'networking_genie'

# first run class
class FirstRunInit
  include Utilities
  include Curses

  def initialize(logger, alert_queue_manager, db_manager = nil)
    @loggman = logger
    @db_manager = db_manager
    @alert_queue_manager = alert_queue_manager
    @info_gatherer = SystemInformationGather.new(@db_manager, @loggman)
    Dotenv.load
  end

  def run
    first_run_setup
  end

  def first_run_setup # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    ask_for_db_details
    dec_pass = decrypt_string_chacha20(ENV['DB_PASSWORD'], ENV['DB_SECRET_KEY'])
    connection_established = @db_manager.test_db_connection(ENV['DB_USERNAME'], dec_pass.to_s, ENV['DB_DATABASE'])

    until connection_established
      Curses.setpos(4, 0)
      alert = Alert.new("We couldn't connect to the database with the details you provided Please try again!", :warning)
      @alert_queue_manager.enqueue_alert(alert)
      Curses.refresh
      ask_for_db_details
      connection_established = @db_manager.test_db_connection(ENV['DB_USERNAME'], dec_pass.to_s, ENV['DB_DATABASE'])
    end

    @db_manager.create_system_info_table
    @db_manager.create_services_table

    uplink_speed = @info_gatherer.ask_for_uplink_speed
    downlink_speed = @info_gatherer.ask_for_downlink_speed
    total_bandwidth = calculate_total_bandwidth(uplink_speed, downlink_speed)
    services = @info_gatherer.ask_for_services

    system_info = {
      uplink_speed:,
      downlink_speed:,
      total_bandwidth:
    }

    @db_manager.store_system_info(system_info)
    @db_manager.store_services(services)

    # ask for sudo permissions to setup the networking stuff we need
    ask_for_sudo(@loggman)

    # Set up networking
    networking_genie = NetworkingGenie.new(@loggman, @alert_queue_manager)
    main_interface = networking_genie.find_main_interface
    dummy_interface = networking_genie.create_dummy_interface('netrave0')
    networking_genie.setup_traffic_mirroring(main_interface, dummy_interface)
  end

  def ask_for_db_details # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
    @loggman.log_info('Asking for Database details...')
    Curses.clear

    Curses.setpos(1, 0)
    Curses.addstr('Please enter your database username: ')
    Curses.refresh
    username = DCI.catch_input(true)
    @loggman.log_info('Database Username entered!')

    Curses.setpos(2, 0)
    Curses.addstr('Please enter your database password: ')
    Curses.refresh
    Curses.noecho
    password = DCI.catch_input(false)
    @loggman.log_info('Database Password Stored Securely!')
    Curses.echo

    Curses.setpos(3, 0)
    Curses.addstr('Please enter your database name: ')
    Curses.refresh
    database = DCI.catch_input(true)
    @loggman.log_info('Database Name entered!')

    # Generate a secret key
    key = generate_key
    @loggman.log_info('Secret Key Generated!')

    # Encrypt the password
    encrypted_password = encrypt_string_chacha20(password, key)
    @loggman.log_info('Password Encrypted!')

    db_details = { username:, password: encrypted_password, key:, database: }
    write_db_details_to_config_file(db_details)
    @loggman.log_info('Wiriting Database details to a file!')
  end

  def write_db_details_to_config_file(db_details) # rubocop:disable Metrics/MethodLength
    # Write the database details to the .env file
    File.open('.env', 'w') do |file|
      file.puts %(DB_USERNAME="#{db_details[:username]}")
      file.puts %(DB_PASSWORD="#{db_details[:password]}")
      file.puts %(DB_SECRET_KEY="#{db_details[:key]}")
      file.puts %(DB_DATABASE="#{db_details[:database]}")
    end

    @loggman.log_info('Database details saved! Reloading environment...')
    # Load the .env file using dotenv
    Dotenv.load
    @loggman.log_info('Environment restarted!')
  rescue StandardError => e
    @loggman.log_error("Failed to write to .env file: #{e.message}")
  end

  def ask_for_default_mode
    loop do
      Curses.setpos(8, 0)
      Curses.addstr('Please enter the default mode (TUI, GUI, or WebApp): ')
      Curses.refresh
      mode = Curses.getstr.strip.downcase
      return mode if valid_mode?(mode)

      Curses.setpos(9, 0)
      Curses.addstr("Whoops! That didn't appear to be a valid mode. Please try again!")
      Curses.refresh
    end
  end

  def valid_mode?(mode)
    %w[tui gui webapp].include?(mode)
  end
end
