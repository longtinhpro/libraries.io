class RepositoryOrganisation < ApplicationRecord
  API_FIELDS = [:name, :login, :blog, :email, :location, :bio]

  has_many :repositories
  has_many :source_repositories, -> { where fork: false }, anonymous_class: Repository
  has_many :open_source_repositories, -> { where fork: false, private: false }, anonymous_class: Repository
  has_many :dependencies, through: :open_source_repositories
  has_many :favourite_projects, -> { group('projects.id').order("COUNT(projects.id) DESC, projects.rank DESC NULLS LAST") }, through: :dependencies, source: :project
  has_many :all_dependent_repos, -> { group('repositories.id') }, through: :favourite_projects, source: :repository
  has_many :contributors, -> { group('repository_users.id').order("sum(contributions.count) DESC") }, through: :open_source_repositories, source: :contributors
  has_many :projects, through: :open_source_repositories

  validates :login, uniqueness: {scope: :host_type}, if: lambda { self.login_changed? }
  validates :uuid, uniqueness: {scope: :host_type}, if: lambda { self.uuid_changed? }

  after_commit :async_sync, on: :create

  scope :most_repos, -> { joins(:open_source_repositories).select('repository_organisations.*, count(repositories.id) AS repo_count').group('repository_organisations.id').order('repo_count DESC') }
  scope :most_stars, -> { joins(:open_source_repositories).select('repository_organisations.*, sum(repositories.stargazers_count) AS star_count, count(repositories.id) AS repo_count').group('repository_organisations.id').order('star_count DESC') }
  scope :newest, -> { joins(:open_source_repositories).select('repository_organisations.*, count(repositories.id) AS repo_count').group('repository_organisations.id').order('created_at DESC').having('count(repositories.id) > 0') }
  scope :visible, -> { where(hidden: false) }
  scope :with_login, -> { where("repository_organisations.login <> ''") }
  scope :host, lambda{ |host_type| where('lower(repository_organisations.host_type) = ?', host_type.try(:downcase)) }

  delegate :avatar_url, :repository_url, :top_favourite_projects, :top_contributors,
           :to_s, :to_param, :github_id, to: :repository_owner

  def repository_owner
    RepositoryOwner::Gitlab
    @repository_owner ||= RepositoryOwner.const_get(host_type.capitalize).new(self)
  end

  def meta_tags
    {
      title: "#{self} on #{host_type}",
      description: "#{host_type} repositories created by #{self}",
      image: avatar_url(200)
    }
  end

  def contributions
    Contribution.none
  end

  def org?
    true
  end

  def company
    nil
  end

  def github_client
    AuthToken.client
  end

  def user_type
    'Organisation'
  end

  def followers
    0
  end

  def following
    0
  end

  def self.create_from_github(login_or_id)
    begin
      r = AuthToken.client.org(login_or_id).to_hash
      return false if r.blank?

      org = nil
      org_by_id = RepositoryOrganisation.host('GitHub').find_by_uuid(r[:id])
      if r[:login].present?
        org_by_login = RepositoryOrganisation.host('GitHub').where("lower(login) = ?", r[:login].downcase).first
      else
        org_by_login = nil
      end

      if org_by_id # its fine
        if org_by_id.login.try(:downcase) == r[:login].try(:downcase)
          org = org_by_id
        else
          if org_by_login && !org_by_login.download_from_github
            org_by_login.destroy
          end
          org_by_id.login = r[:login]
          org_by_id.save!
          org = org_by_id
        end
      elsif org_by_login # conflict
        if org_by_login.download_from_github_by_login
          org = org_by_login if org_by_login.github_id == r[:id]
        end
        org_by_login.destroy if org.nil?
      end
      if org.nil?
        org = RepositoryOrganisation.create!(uuid: r[:id], login: r[:login], host_type: 'GitHub')
      end

      org.assign_attributes r.slice(*RepositoryOrganisation::API_FIELDS)
      org.save
      org
    rescue *RepositoryHost::Github::IGNORABLE_EXCEPTIONS
      false
    end
  end

  def async_sync
    RepositoryUpdateOrgWorker.perform_async(self.login)
  end

  def sync
    download_from_github
    download_repos
    update_attributes(last_synced_at: Time.now)
  end

  def download_from_github
    download_from_github_by(github_id)
  end

  def download_from_github_by_login
    download_from_github_by(login)
  end

  def download_from_github_by(id_or_login)
    RepositoryOrganisation.create_from_github(github_client.org(id_or_login))
  rescue *RepositoryHost::Github::IGNORABLE_EXCEPTIONS
    nil
  end

  def download_repos
    github_client.org_repos(login).each do |repo|
      CreateRepositoryWorker.perform_async('GitHub', repo.full_name)
    end
  rescue *RepositoryHost::Github::IGNORABLE_EXCEPTIONS
    nil
  end

  def find_repositories
    Repository.host(host_type).where('full_name ILIKE ?', "#{login}/%").update_all(repository_user_id: nil, repository_organisation_id: self.id)
  end
end
