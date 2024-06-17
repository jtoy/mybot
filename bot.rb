require 'active_record'
require 'telegram/bot'
require 'dotenv/load'
require 'nokogiri'
require 'ostruct'
require 'http'

class Link < ActiveRecord::Base
  validates :url, presence: true, format: URI::regexp(%w[http https])
  #validates :title #, presence: true
  validates :user_id, presence: true
end


db_config = YAML.load_file('config/database.yml')
ActiveRecord::Base.establish_connection(db_config['development'])

class CreateLinksTable < ActiveRecord::Migration[6.0]
  def change
    unless table_exists?(:links)
      create_table :links do |t|
        t.string :url, null: false
        t.string :title
        t.text :notes
        t.integer :user_id,null:false
        t.timestamps
      end
    end
  end
end

# Run the migration
CreateLinksTable.migrate(:up)


class Fetcher
  def self.fetch(url)
    response = HTTP.get(url)
    if response.status.success?
      html = Nokogiri::HTML(response.to_s)
      o = OpenStruct.new(
        title: html&.title,
        status: response.status,
        url: url
      )
    else
      "No Title Found"
    end
  rescue => e
    "Error: #{e.message}"
  end
end

def list_links(message, bot)
  links = Link.where(user_id: message.from.id)

  if links.any?
    response = "Your saved links:\n"
    links.each_with_index do |link, index|
      response += "#{index + 1}. #{link.url}\nTitle: #{link.title}\nNotes: #{link.notes}\n\n"
    end
  else
    response = "You haven't saved any links yet."
  end

  bot.api.send_message(chat_id: message.chat.id, text: response)
end

URL_REGEX = %r{https?://[\S]+}
Telegram::Bot::Client.run(ENV.fetch("TELEGRAM_BOT_API_TOKEN")) do |bot|
  bot.listen do |message|
    case message.text
    when '/list'
      list_links(message, bot)
    else
      parts = message.text.split(' ')
      url = parts.find { |part| part.match(URL_REGEX) }
      notes = parts.reject { |part| part.match(URL_REGEX) }.join(' ')
      if url
        existing_link = Link.find_by(url: url)
        if existing_link
          bot.api.send_message(chat_id: message.chat.id, text: "Duplicate link found!\nTitle: #{existing_link.title}\nNotes: #{existing_link.notes}")
        else
          o = Fetcher.fetch(url) rescue nil
          puts o.inspect
          link = Link.new(url: url,title:o.title,user_id: message.from.id,notes:notes)
          if link.save
            bot.api.send_message(chat_id: message.chat.id, text: "Link saved!")
          else
            bot.api.send_message(chat_id: message.chat.id, text: "Invalid link. #{link.errors}")
          end
        end
      end
    end
  end
end
