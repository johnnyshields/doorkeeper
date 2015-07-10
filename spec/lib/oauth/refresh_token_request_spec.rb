require 'spec_helper_integration'

module Doorkeeper::OAuth
  describe RefreshTokenRequest do
    let(:server) do
      double :server,
             access_token_expires_in: 2.minutes,
             custom_access_token_expires_in: -> (_oauth_client) { nil },
             refresh_token_revoked_in: 0
    end
    let(:refresh_token) do
      FactoryGirl.create(:access_token, use_refresh_token: true)
    end
    let(:client) { refresh_token.application }
    let(:credentials) { Client::Credentials.new(client.uid, client.secret) }

    subject { RefreshTokenRequest.new server, refresh_token, credentials }

    it 'issues a new token for the client' do
      expect { subject.authorize }.to change { client.access_tokens.count }.by(1)
      expect(client.reload.access_tokens.last.expires_in).to eq(120)
    end

    it 'issues a new token for the client with custom expires_in' do
      server = double :server,
                      access_token_expires_in: 2.minutes,
                      custom_access_token_expires_in: ->(_oauth_client) { 1234 },
                      refresh_token_revoked_in: 0

      RefreshTokenRequest.new(server, refresh_token, credentials).authorize

      expect(client.reload.access_tokens.last.expires_in).to eq(1234)
    end

    it 'revokes the previous token' do
      expect { subject.authorize }.to change { refresh_token.revoked? }.from(false).to(true)
    end

    it 'requires the refresh token' do
      subject.refresh_token = nil
      subject.validate
      expect(subject.error).to eq(:invalid_request)
    end

    it 'requires credentials to be valid if provided' do
      subject.client = nil
      subject.validate
      expect(subject.error).to eq(:invalid_client)
    end

    it "requires the token's client and current client to match" do
      subject.client = FactoryGirl.create(:application)
      subject.validate
      expect(subject.error).to eq(:invalid_grant)
    end

    it 'rejects revoked tokens' do
      refresh_token.revoke
      subject.validate
      expect(subject.error).to eq(:invalid_grant)
    end

    it 'accepts expired tokens' do
      refresh_token.expires_in = -1
      refresh_token.save
      subject.validate
      expect(subject).to be_valid
    end

    context 'refresh tokens expire on access token use' do
      let(:server) do
        double :server,
               access_token_expires_in: 2.minutes,
               custom_access_token_expires_in: ->(_oauth_client) { 1234 },
               refresh_token_revoked_in: 1.day
      end

      it 'issues a new token for the client' do
        expect { subject.authorize }.to change { client.access_tokens.count }.by(1)
      end

      it 'does not revoke the previous token' do
        subject.authorize
        expect(refresh_token).not_to be_revoked
      end

      it 'sets the previous refresh token in the new access token' do
        subject.authorize
        expect(client.access_tokens.last.previous_refresh_token).to eq(refresh_token.refresh_token)
      end
    end

    context 'longer lived refresh tokens' do
      let(:server) do
        double :server,
               access_token_expires_in: 2.minutes,
               custom_access_token_expires_in: ->(_oauth_client) { 1234 },
               refresh_token_revoked_in: 1.day
      end

      before do
        @time = Time.now.round
        Timecop.freeze(@time)
      end

      it 'sets the revoke time of the previous token' do
        expect { subject.authorize }.to change { refresh_token.revoked_at }.from(nil).to(@time.advance(days: 1))
      end

      context 'revoked token' do
        let!(:refresh_token) { FactoryGirl.create(:access_token, use_refresh_token: true, revoked_at: @time.advance(days: 1)) }

        it 'does not change the revoke time of an already revoked token' do
          expect { subject.authorize }.not_to change { refresh_token.revoked_at }
        end
      end
    end

    context 'clientless access tokens' do
      let!(:refresh_token) { FactoryGirl.create(:clientless_access_token, use_refresh_token: true) }

      subject { RefreshTokenRequest.new server, refresh_token, nil }

      it 'issues a new token without a client' do
        expect { subject.authorize }.to change { Doorkeeper::AccessToken.count }.by(1)
      end
    end

    context 'with scopes' do
      let(:refresh_token) do
        FactoryGirl.create :access_token,
                           use_refresh_token: true,
                           scopes: 'public write'
      end
      let(:parameters) { {} }
      subject { RefreshTokenRequest.new server, refresh_token, credentials, parameters }

      it 'transfers scopes from the old token to the new token' do
        subject.authorize
        expect(Doorkeeper::AccessToken.last.scopes).to eq([:public, :write])
      end

      it 'reduces scopes to the provided scopes' do
        parameters[:scopes] = 'public'
        subject.authorize
        expect(Doorkeeper::AccessToken.last.scopes).to eq([:public])
      end

      it 'validates that scopes are included in the original access token' do
        parameters[:scopes] = 'public update'

        subject.validate
        expect(subject.error).to eq(:invalid_scope)
      end

      it 'uses params[:scope] in favor of scopes if present (valid)' do
        parameters[:scopes] = 'public update'
        parameters[:scope] = 'public'
        subject.authorize
        expect(Doorkeeper::AccessToken.last.scopes).to eq([:public])
      end

      it 'uses params[:scope] in favor of scopes if present (invalid)' do
        parameters[:scopes] = 'public'
        parameters[:scope] = 'public update'

        subject.validate
        expect(subject.error).to eq(:invalid_scope)
      end
    end
  end
end
