require 'bundler/setup'
Bundler.setup
Bundler.require

# Load configurations, libraries, concerns, and models
if development?
  require 'dotenv'
  Dotenv.load
end

Dir['{config,concerns}/*.rb'].each { |f| require_relative f }

require_relative "lib/mirror_image"
require_relative "lib/rate_limiter"

require_relative "models/config"
require_relative "models/user"
require_relative "models/post"
require_relative "models/comment"

# App-wide constants
AUTH_PROVIDER = ENV['AUTH_PROVIDER'] || "GitHub"
ABOUT_PAGE = Post[uid: 'about']
DESCRIPTION_PAGE = Post[uid: 'description']
EXTRA_STYLESHEETS = Config[:stylesheets]
SITE_NAME = Config[:site_name] || ENV['SITE_NAME'] || "flow2"
SITE_DESCRIPTION = Config[:site_description] || ENV['SITE_DESCRIPTION'] || "a linkflow site"
BLACKLIST = File.readlines(File.join(__dir__, 'config', 'blacklist.txt')).select { |l| l =~ /^\w+/ }.map { |l| l.strip }

module Flow
  class App < Sinatra::Base
    configure do
      # Rack middleware
      use Rack::Deflater
      use Rack::Session::Cookie,
                     :key => (Config[:cookie_key]  || 'flow.session'),
                     :path => '/',
                     :expire_after => (Config[:cookie_timeout] || 86400 * 90),
                     :secret => ENV["SECRET"] || "put something rather unique here"
      use Rack::Flash
      use OmniAuth::Builder do
        provider(:github, ENV['OAUTH_PROVIDER_KEY'] || ENV['GITHUB_KEY'], ENV['OAUTH_PROVIDER_SECRET'] || ENV['GITHUB_SECRET'], scope: 'user:email') if AUTH_PROVIDER.to_s.downcase == 'github'
        provider(:twitter, ENV['OAUTH_PROVIDER_KEY'] || ENV['TWITTER_KEY'], ENV['OAUTH_PROVIDER_SECRET'] || ENV['TWITTER_SECRET'], scope: 'user:email') if AUTH_PROVIDER.to_s.downcase == 'twitter'
        provider(:facebook, ENV['OAUTH_PROVIDER_KEY'] || ENV['FACEBOOK_KEY'], ENV['OAUTH_PROVIDER_SECRET'] || ENV['FACEBOOK_SECRET'], scope: 'email') if AUTH_PROVIDER.to_s.downcase == 'facebook'
      end

      if test?
        require 'rack_session_access'
        require 'rack_session_access/middleware'
        require 'rack_session_access/capybara'
        use RackSessionAccess::Middleware #, key: 'flow.session'
      end

      # Asset pipeline configuration
      register Sinatra::AssetPipeline
      set :sprockets, Sprockets::Environment.new(root)
      set :assets_prefix, '/assets'
      set :digest_assets, production?

      sprockets.append_path File.join(root, 'assets', 'css')
      sprockets.append_path File.join(root, 'assets', 'js')

      Sprockets::Helpers.configure do |config|
        config.environment = sprockets
        config.prefix      = assets_prefix
        config.digest      = digest_assets
        config.public_path = public_folder
        config.debug       = true if development?
      end

      # If the New Relic plugin is installed, run it up
      require 'newrelic_rpm' if ENV['NEW_RELIC_LICENSE_KEY'] && production?
    end

    helpers do
      include Sprockets::Helpers
      include RateLimiter

      # HTML-safe rendering of text
      def h(text)
        Rack::Utils.escape_html(text)
      end

      # Return the currently logged in user, if any
      def current_user
        session[:logged_in] && User[session[:logged_in]]
      end

      def logged_in?; current_user end

      def admin?
        logged_in? && current_user.admin?
      end

      # What page is the user attempting to view?
      def determine_page
        @offset = 0
        @page = 1

        if params[:page].to_i > 0
          @page = params[:page].to_i
          @offset = (@page - 1) * Post::POSTS_PER_PAGE
        end
      end

      def internal_visitor?
        request.referer && request.referer.include?(request.host)
      end

      def with_avatar
        current_user && current_user.avatar?
      end
    end

    # Things to do or check before every request
    before do
      # Classes we might wish to set on the <body> tag
      @body_classes = []

      # If the URL is www, redirect any non-www variants to it
      if ENV['BASE_URL'] =~ /\/\/www\./ && request.host !~ /^www/
        redirect request.url.sub(/\/\//, '//www.'), 301
      end

      # And vice versa (www to non-www)
      if ENV['BASE_URL'] !~ /\/\/www\./ && request.host =~ /^www/
        redirect request.url.sub(/www\./, ''), 301
      end
    end

    # Homepage
    get '/' do
      redirect '/rss', 301 if params[:format].to_s == 'rss'    # Compatibility with older flow sites

      rate_limit requests: 50, within: 40

      @body_classes << 'index'
      determine_page
      @posts = Post.recent_from_offset(@offset)

      if request.xhr?
        erb :posts, layout: false
      else
        erb :index
      end
    end

    # The RSS feed
    get '/rss' do
      @posts = Post.recent_from_offset(@offset)
      content_type :rss
      Cache[:posts_rss] ||= builder :posts
    end

    # Show an individual post's page
    get '/p/:id' do
      rate_limit requests: 50, within: 40

      # The unique ID is only the first part of the URL due to the presence of the slug
      # For example /p/abcd-this-is-a-test, only "abcd" is the unique post ID
      id = params[:id].split('-').first
      @body_classes << 'post'
      @post = Post.find(uid: id)

      # Trigger an edit mode flag if editing is the intention
      @editing = params[:edit] && params[:edit] == 'true'

      # But don't let someone try to edit a post if they're not allowed to
      halt 403 if @editing && !@post.can_be_edited_by?(current_user)

      if @post
        @page_title = @post.title
      else
        status 404
      end

      erb :post
    end


    # --- POSTING AND COMMENTING URLS
    # You can tell I really don't give a care about REST on this project so far ;-)
    # And I really don't.

    # Delete a post, if allowed to
    delete '/post/:uid' do
      post = Post.find_where_editable_by(current_user, uid: params[:uid])
      halt 404 unless post

      post.delete

      Cache.expire(:front_page)

      content_type :json
      erb({ success: true }.to_json, layout: false)
    end

    # Delete a comment, if allowed to
    delete '/comment/:id' do
      comment = Comment.find_where_editable_by(current_user, id: params[:id])
      halt 404 unless comment

      comment.delete

      Cache.expire(:front_page)

      content_type :json
      erb({ success: true }.to_json, layout: false)
    end

    # Create a new post
    post '/post' do
      # If we're trying to edit an existing post, grab that post if we're allowed to
      post = Post.find_where_editable_by(current_user, uid: params[:post_uid]) if params[:post_uid]

      if logged_in?
        post ||= Post.new
        post.title = params[:title]
        post.user ||= current_user
        post.content = params[:content]
        post.visible = false if current_user.metadata['shadowbanned']

        unless post.valid?
          content_type :json
          halt erb({ errors: post.errors_list }.to_json, layout: false)
        end

        if params[:preview]
          content_type :json
          halt erb({ preview: { title: post.title, content: post.rendered_content } }.to_json, layout: false)
        end

        unless within_rate_limit(:posting, requests: 1, within: 10)
          content_type :json
          halt erb({ errors: [['content', 'You have posted within the past five minutes']] }.to_json, layout: false)
        end

        post.save
        Cache.expire(:front_page)
        Cache.expire('post:' + post.uid)

        flash[:notice] = "Your post has been saved - thanks!"

        if request.xhr?
          content_type :json
          erb({ redirect_to_post: post.url }.to_json, layout: false)
        else
          redirect post.url
        end
      else
        content_type :json
        session[:return_to] = ENV['BASE_URL'] + "#submitform"
        erb({ redirect_to_oauth: AUTH_PROVIDER.downcase }.to_json, layout: false)
      end
    end

    # Create a new comment
    post '/comment' do
      post = Post.find(uid: params[:post_id])

      # If we're trying to edit an existing comment, grab it only if we're allowed to
      comment = Comment.find_where_editable_by(current_user, id: params[:comment_id]) if params[:comment_id]

      halt 400 unless post

      if logged_in?
        comment ||= Comment.new
        comment.user = current_user
        comment.post = post
        comment.content = params[:content]

        unless comment.valid?
          content_type :json
          halt erb({ errors: comment.errors_list }.to_json, layout: false)
        end

        unless within_rate_limit(:commenting, requests: 6, within: 120)
          content_type :json
          halt erb({ errors: [['content', 'Slow down the commenting a little']] }.to_json, layout: false)
        end

        comment.save
        Cache.expire('post:' + comment.post.uid)

        flash[:notice] = "Your comment has been posted - thanks!"

        if request.xhr?
          content_type :json
          erb({ redirect_to_post: comment.post.url, comment_id: comment.id }.to_json, layout: false)
        else
          redirect comment.post.url + "#comment-" + comment.id
        end
      else
        content_type :json
        session[:return_to] = post.url + "#postcomment"
        erb({ redirect_to_oauth: AUTH_PROVIDER.downcase }.to_json, layout: false)
      end
    end


    # --- AUTHENTICATION URLS

    get '/logout' do
      session[:logged_in] = false
      flash[:notice] = "You have logged out"
      redirect '/'
    end

    # OmniAuth callback used by external auth providers
    get '/auth/' + AUTH_PROVIDER.downcase + '/callback' do
      # Be sure we're receiving everything we want to receive
      r = request.env['omniauth.auth']
      halt 401 unless r.is_a?(Hash)

      provider = r['provider']
      uid = r['uid']
      halt 401 unless provider && uid && r['info']

      # Find if there's a user associated with the external ID being sent
      u = User.find(external_uid: uid)

      # If there is, we're logged in, hurrah.
      if u
        session[:logged_in] = u.id
      else
        # Otherwise, create a user based on the information received
        begin
          u = User.new
          u.username = r['info']['nickname']
          u.email = r['info']['email']
          u.metadata['provider'] = provider
          u.external_uid = uid
          u.external_token = r['credentials']['token']
          u.fullname = r['info']['name']

          # Do they have an image/avatar at the auth provider? If so, mirror it.
          if r['info']['image'] && S3::CLIENT
            fn = u.username.to_s + uid.to_s
            # Since it's not essential, we'll rescue this away if the upload fails
            u.avatar_url = MirrorImage.mirror_image_to_s3(r['info']['image'], fn)
          end

          u.save

          # If the user is the first user in the entire system, make them an admin
          u.admin! if User.count == 1

          session[:logged_in] = u.id
        rescue
          # If all else fails, I'm a Teapot.
          # TODO: This may occur if the username is not unique, so deal with it better!
          halt 418

          # OK, in reality, the main reason this error would occur is
          # because the UID at the auth provider is different to what we have
          # stored. This should never change but could if you switched auth
          # providers. So in this situation, we'd probably need to either:
          #   - update the UID on the record based on the username
          #   - create a record with a slightly different username
          #   - ask the user what to do
          # Ideas on a postcard, please.
        end
      end

      # We're logged in, we hope.
      flash[:notice] = "You are now logged in."

      if session[:return_to].to_s =~ /submitform/
        flash[:notice] = "You are now logged in and can submit your post to the site"
      end

      if u.admin?
        flash[:warning] = "Please note that you are an admin"
      end

      flash[:oauth_successful] = true

      # Return to what the user was doing, if we know what that was, otherwise the root URL
      redirect session[:return_to] || ENV['BASE_URL'] || '/'
    end

    # External auth failed
    get '/auth/failure' do
      # TODO: Show a nicer message than this
      erb "<h1>Authentication failed</h1>"
    end

    # The external auth provider isn't liking us
    get '/auth/:provider/deauthorized' do
      # TODO: Show a nicer message than this
      erb "<h1>#{params[:provider]} has deauthorized this app.</h1>"
    end


    # --- COMPATIBILITY URLS

    # For compatibility with old flow sites for SEO/usability purposes
    get '/page/:page' do
      redirect(ENV['BASE_URL'] + "?page=" + params[:page], 301)
    end

    get '/items/:id' do
      redirect(ENV['BASE_URL'] + %{/p/#{params[:id]}}, 301)
    end

    get '/users/:id' do
      flash[:warning] = "User profile pages are not currently available, they will return soon"
      redirect ENV['BASE_URL']
    end

    get '/signup' do
      flash[:notice] = "You no longer need to sign up, just start posting"
      redirect ENV['BASE_URL']
    end

    get '/login' do
      flash[:notice] = "You no longer need to log in, it happens automatically when you try to do something"
      redirect ENV['BASE_URL']
    end

    # If this is being run directly, let it serve the app up
    run! if app_file == $0
  end
end
