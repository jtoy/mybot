require 'active_record'
require 'telegram/bot'
require 'dotenv/load'
require 'nokogiri'
require 'ostruct'
require 'http'
require './llm'
require 'rufus-scheduler'

class Link < ActiveRecord::Base
  validates :url, presence: true, format: URI::regexp(%w[http https])
  #validates :title #, presence: true
  validates :user_id, presence: true
end

class Message < ActiveRecord::Base
  validates :user_id, presence: true
  validates :content, presence: true
  validates :role, presence: true, inclusion: { in: ['user', 'assistant'] }
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
    unless table_exists?(:messages)
      create_table :messages do |t|
        t.integer :user_id, null: false
        t.text :content, null: false
        t.string :role, null: false
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
def save_message(user_id, content, role)
  Message.create!(
    user_id: user_id,
    content: content,
    role: role
  )
end
def get_conversation_history(user_id)
  Message.where(user_id: user_id)
        .order(created_at: :desc)
        .limit(10)
        .map { |msg| "#{msg.role}: #{msg.content}" }
        .reverse
        .join("\n")
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

# Initialize scheduler
scheduler = Rufus::Scheduler.new

# Store user intentions
$user_intentions = {}

def ask_for_intention(bot, chat_id)
  bot.api.send_message(
    chat_id: chat_id,
    text: "Good morning! What is your intention for today?"
  )
end

def make_suggestion(bot, chat_id, intention)
  return unless intention
  
  prompt = "Given the user's intention for today: '#{intention}', provide ONE specific, actionable suggestion for achieving this goal. Keep it brief and motivational. Don't mention the time."
  suggestion = Llm.go(prompt: prompt)
  
  bot.api.send_message(
    chat_id: chat_id,
    text: suggestion
  )
end

# Schedule daily intention check at 8:30 AM
scheduler.cron '30 8 * * *' do
  $user_intentions.keys.each do |chat_id|
    ask_for_intention(bot, chat_id)
  end
end

scheduler.cron "30 11 * * *" do
  $user_intentions.each do |chat_id, intention|
    make_suggestion(bot, chat_id, intention)
  end
end

URL_REGEX = %r{https?://[\S]+}
Telegram::Bot::Client.run(ENV.fetch("TELEGRAM_BOT_API_TOKEN")) do |bot|
  bot.listen do |message|
    case message.text
    when '/start'
      $user_intentions[message.chat.id] = nil
      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Welcome! I'll ask for your daily intention at 8:30 AM and provide suggestions throughout the day."
      )
    when '/list'
      list_links(message, bot)
    else
      # Store intention if it was just requested
      if $user_intentions[message.chat.id].nil?
        $user_intentions[message.chat.id] = message.text
        response = "Thank you! I'll help you work towards: #{message.text}"
        save_message(message.from.id, message.text, 'user')
        save_message(message.from.id, response, 'assistant')
        bot.api.send_message(
          chat_id: message.chat.id,
          text: response
        )
        next
      end
      
      # Original URL handling logic
      parts = message.text.split(' ')
      url = parts.find { |part| part.match(URL_REGEX) }
      
      if url
        existing_link = Link.find_by(url: url)
        save_message(message.from.id, message.text, 'user')
        
        if existing_link
          response = "Duplicate link found!\nTitle: #{existing_link.title}\nNotes: #{existing_link.notes}"
          save_message(message.from.id, response, 'assistant')
          bot.api.send_message(chat_id: message.chat.id, text: response)
        else
          o = Fetcher.fetch(url) rescue nil
          puts o.inspect
          notes = parts.reject { |part| part.match(URL_REGEX) }.join(' ')
          link = Link.new(url: url,title:o.title,user_id: message.from.id,notes:notes)
          if link.save
            response = "Link saved!"
            save_message(message.from.id, response, 'assistant')
            bot.api.send_message(chat_id: message.chat.id, text: response)
          else
            response = "Invalid link. #{link.errors}"
            save_message(message.from.id, response, 'assistant')
            bot.api.send_message(chat_id: message.chat.id, text: response)
          end
        end
      else
        save_message(message.from.id, message.text, 'user')
        history = get_conversation_history(message.from.id)
        prompt = "Previous conversation:\n#{history}\n\nRespond to user's message: #{message.text}"
        #response = Llm.go(prompt: prompt,model:"gemini-1.5-flash-8b")
        response = Llm.go(prompt: prompt,model:"llama3.2",service: :local)
        save_message(message.from.id, response, 'assistant')
        bot.api.send_message(chat_id: message.chat.id, text: response)
      end
    end
  end
end


