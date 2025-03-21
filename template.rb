# frozen_string_literal: true
# This file is used to generate a Rails application with the specified configuration.

gem 'strong_migrations', require: false
gem 'view_component'
gem 'httparty'
gem 'pagy', '~> 9.3'
gem 'pundit'
gem 'devise'
gem "amazing_print"
gem "rails_semantic_logger"
gem 'sorbet-runtime'

gem_group :development, :test do
  gem "rspec-rails"
  gem 'faker'
  gem 'factory_bot_rails'
  gem 'byebug'
  gem 'dotenv'
  gem 'tapioca', require: false
end

gem_group :development do
  gem 'sorbet'
  gem "annotaterb"
  gem 'letter_opener'
  gem 'letter_opener_web', '~> 3.0'
  gem "lookbook", ">= 2.3.8"
end

gem_group :test do
  gem 'simplecov', require: false
end

# Set the source paths for file operations
def source_paths
  [File.expand_path(__dir__), File.expand_path(File.join(__dir__, 'templates'))]
end


after_bundle do
  rails_command 'active_storage:install'
  rails_command 'g rspec:install'
  rails_command "g devise:install"
  user_models = ask('What User models do you want to use? (e.g. User, Admin, etc.)?').presence || "User"
  user_models = user_models.split(',').map(&:strip)
  user_models.each do |model|
    model = model.camelize
    generate "devise #{model}"
  end
  rails_command 'g annotate_rb:install'
  rails_command 'g strong_migrations:install'
  rails_command 'g actiontext:install'
  rails_command 'g pundit:install'

  run 'bundle exec tapioca init'

  inject_into_file "app/views/layouts/application.html.erb", before: "</body>" do
    <<-ERB

      <% flash.each do |key, message| %>
        <div class="alert alert-<%= key %>"><%= message %></div>
      <% end %>
    ERB
  end
end

require "open-uri"
pagy_content = URI.open("https://raw.githubusercontent.com/jurgen1c/rails-boilerplate/main/templates/pagy.rb").read
initializer 'pagy.rb', pagy_content

empty_directory 'app/views/components'
av_content = URI.open("https://raw.githubusercontent.com/jurgen1c/rails-boilerplate/main/templates/application_view_component.rb").read
say_status("fetch", "Downloading remote templates tarball...", :blue)
# Your tarball extraction code...
create_file 'app/views/components/application_view_component.rb', av_content
say_status("create", "Created Application View component", :green)

empty_directory 'app/views/components/concerns'
styles_content = URI.open("https://raw.githubusercontent.com/jurgen1c/rails-boilerplate/main/templates/style_variants.rb").read
create_file 'app/views/components/concerns/style_variants.rb', styles_content

empty_directory 'app/rest_clients'
ar_content = URI.open("https://raw.githubusercontent.com/jurgen1c/rails-boilerplate/main/templates/application_rest_client.rb").read
create_file 'app/rest_clients/application_rest_client.rb', ar_content

empty_directory 'app/services'
as_content = URI.open("https://raw.githubusercontent.com/jurgen1c/rails-boilerplate/main/templates/application_service.rb").read
create_file 'app/services/application_service.rb', as_content

empty_directory 'spec/support'
create_file "spec/support/factory_bot.rb", <<-CODE
  RSpec.configure do |config|
    config.include FactoryBot::Syntax::Methods
  end
CODE

inject_into_class "app/controllers/application_controller.rb", "ApplicationController", <<-RUBY

  include Pagy::Backend
RUBY

inject_into_file "app/helpers/application_helper.rb", after: "module ApplicationHelper\n" do
  <<-RUBY
  include Pagy::Frontend
  RUBY
end

environment 'config.action_mailer.delivery_method = :letter_opener', env: 'development'
environment <<-CODE
   config.generators do |g|
      g.system_tests = nil
      g.orm :active_record, primary_key_type: :uuid
      g.test_framework :rspec
      g.factory_bot suffix: "factory"
    end

    config.view_component.view_component_path = 'app/views/components'
    config.eager_load_paths << Rails.root.join('app/views/components')
    config.view_component.generate.sidecar = true
    config.view_component.generate.preview = true
    config.view_component.component_parent_class = 'ApplicationViewComponent'
    config.view_component.preview_paths << Rails.root.join('spec/components/previews').to_s
  CODE

route 'mount LetterOpenerWeb::Engine, at: "/letter_opener" if Rails.env.development?'

create_file "postcss.config.js", <<-JS
module.exports = {
  plugins: [
    require('postcss-import'),
    require('tailwindcss'),
    require('autoprefixer'),
  ]
}
JS

run 'bun add eslint --dev'
run 'bun add flowbite postcss'

git add: '.'
git commit: "-m 'initial commit'"

say_status("create", "Created initial commit", :green)
rails_command 'db:create'
