require 'digest/sha1'

# Publify user.
class User < ActiveRecord::Base
  include ConfigManager

  belongs_to :profile
  belongs_to :text_filter

  delegate :name, :to => :text_filter, :prefix => true
  delegate :label, :to => :profile, :prefix => true

  has_many :notifications, :foreign_key => 'notify_user_id'
  has_many :notify_contents, :through => :notifications,
    :source => 'notify_content',
    :uniq => true

  has_many :articles, :order => 'created_at DESC'

  serialize :settings, Hash

  attr_accessor :filename

  # Settings
  setting :notify_watch_my_articles,   :boolean, true
  setting :firstname,                  :string, ''
  setting :lastname,                   :string, ''
  setting :nickname,                   :string, ''
  setting :description,                :string, ''
  setting :url,                        :string, ''
  setting :msn,                        :string, ''
  setting :aim,                        :string, ''
  setting :yahoo,                      :string, ''
  setting :twitter,                    :string, ''
  setting :jabber,                     :string, ''
  setting :admin_theme,                :string,  'blue'
  setting :twitter_account,            :string, ''
  setting :twitter_oauth_token,        :string, ''
  setting :twitter_oauth_token_secret, :string, ''
  setting :twitter_profile_image,      :string, ''
  setting :avatar,                     :string, ''
  setting :thumb_avatar,               :string, ''
  setting :medium_avatar,              :string, ''
  setting :large_avatar,               :string, ''

  # echo "publify" | sha1sum -
  class_attribute :salt

  def self.salt
    '20ac4d290c2293702c64b3b287ae5ea79b26a5c1'
  end

  attr_accessor :last_venue

  def initialize(*args)
    super
    self.settings ||= {}
  end

  def first_and_last_name
    return '' unless firstname.present? && lastname.present?
    "#{firstname} #{lastname}"
  end

  def display_names
    [:login, :nickname, :firstname, :lastname, :first_and_last_name].map{|f| send(f)}.delete_if{|e| e.empty?}
  end

  def self.authenticate(login, pass)
    where("login = ? AND password = ? AND state = ?", login, password_hash(pass), 'active').first
  end

  def update_connection_time
    self.last_venue = last_connection
    self.last_connection = Time.now
    self.save
  end

  # These create and unset the fields required for remembering users between browser closes
  def remember_me
    remember_me_for 2.weeks
  end

  def remember_me_for(time)
    remember_me_until time.from_now.utc
  end

  def remember_me_until(time)
    self.remember_token_expires_at = time
    self.remember_token            = Digest::SHA1.hexdigest("#{email}--#{remember_token_expires_at}")
    save(:validate => false)
  end

  def forget_me
    self.remember_token_expires_at = nil
    self.remember_token            = nil
    save(:validate => false)
  end

  def permalink_url(anchor=nil, only_path=false)
    blog = Blog.default # remove me...

    blog.url_for(
      :controller => 'authors',
      :action => 'show',
      :id => login,
      :only_path => only_path
    )
  end

  def default_text_filter
    text_filter
  end

  def self.authenticate?(login, pass)
    user = self.authenticate(login, pass)
    return false if user.nil?
    return true if user.login == login

    false
  end

  def self.find_by_permalink(permalink)
    self.find_by_login(permalink).tap do |user|
      raise ActiveRecord::RecordNotFound unless user
    end
  end

  def project_modules
    profile.project_modules
  end

  # Generate Methods takes from AccessControl rules
  # Example:
  #
  #   def publisher?
  #     profile.label == :publisher
  #   end
  AccessControl.roles.each do |role|
    define_method "#{role.to_s.downcase}?" do
      profile.label.to_s.downcase == role.to_s.downcase
    end
  end

  def self.to_prefix
    'author'
  end

  def password=(newpass)
    @password = newpass
  end

  def password(cleartext = nil)
    if cleartext
      @password.to_s
    else
      @password || read_attribute("password")
    end
  end

  def article_counter
    articles.size
  end

  def display_name
    if !nickname.blank?
      nickname
    elsif !name.blank?
      name
    else
      login
    end
  end

  def permalink
    login
  end

  def admin?
    profile.label == Profile::ADMIN
  end

  def update_twitter_profile_image(img)
    return if self.twitter_profile_image == img
    self.twitter_profile_image = img
    self.save
  end

  def generate_password!
    chars = ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a
    newpass = ""
    1.upto(7) { |i| newpass << chars[rand(chars.size-1)] }
    self.password = newpass
  end

  def has_twitter_configured?
    self.twitter_oauth_token.present? && self.twitter_oauth_token_secret.present?
  end

  protected

  # Apply SHA1 encryption to the supplied password.
  # We will additionally surround the password with a salt
  # for additional security.
  def self.password_hash(pass)
    Digest::SHA1.hexdigest("#{salt}--#{pass}--")
  end

  def password_hash(pass)
    self.class.password_hash(pass)
  end

  before_create :crypt_password

  # Before saving the record to database we will crypt the password
  # using SHA1.
  # We never store the actual password in the DB.
  # But before the encryption, we send an email to user for he can remind his
  # password
  def crypt_password
    EmailNotify.send_user_create_notification self
    write_attribute "password", password_hash(password(true))
    @password = nil
  end

  before_update :crypt_unless_empty

  # If the record is updated we will check if the password is empty.
  # If its empty we assume that the user didn't want to change his
  # password and just reset it to the old value.
  def crypt_unless_empty
    if password(true).empty?
      user = self.class.find(self.id)
      write_attribute "password", user.password
    else
      crypt_password
    end
  end

  before_validation :set_default_profile

  def set_default_profile
    self.profile ||= Profile.find_by_label(User.count.zero? ? 'admin' : 'contributor')
  end

  validates_uniqueness_of :login, :on => :create
  validates_uniqueness_of :email, :on => :create
  validates_length_of :password, :within => 5..40, :if => Proc.new { |user|
    user.read_attribute('password').nil? or user.password.to_s.length > 0
  }

  validates_presence_of :login
  validates_presence_of :email

  validates_confirmation_of :password
  validates_length_of :login, :within => 3..40
end
