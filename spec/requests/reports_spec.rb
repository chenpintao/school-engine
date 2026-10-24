# frozen_string_literal: true

RSpec.describe SchoolEngine::ReportsController do
  fab!(:admin)
  fab!(:moderator)
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post) { Fabricate(:post, topic: topic, user: user) }

  before { SiteSetting.school_engine_enabled = true }

  describe "GET /school/report-categories.json" do
    it "returns the fixed report categories for any logged-in user" do
      sign_in(user)
      get "/school/report-categories.json"
      expect(response.status).to eq(200)
      codes = response.parsed_body["categories"].map { |c| c["code"] }
      expect(codes).to eq(SchoolEngine::ReportCategories::CODES)
      # 敏感词库永不外泄
      expect(response.body).not_to include("人肉")
      expect(response.body).not_to include("自杀")
    end
  end

  describe "POST /school/report.json" do
    it "records a report and puts it in the shared queue" do
      sign_in(user)
      post "/school/report.json", params: { post_id: post.id, category: "bullying", reason: "测试", anonymous: true }
      expect(response.status).to eq(200)
      post.reload
      expect(post.custom_fields["report_cats"]).to eq("bullying")
      expect(post.custom_fields["mod_state"]).to eq("pending")
      expect(post.custom_fields["mod_deadline"]).to be_present
      expect(SchoolEngine::Moderation.events(post).map { |e| e["kind"] }).to include("reported")
    end

    it "rejects invalid categories" do
      sign_in(user)
      post "/school/report.json", params: { post_id: post.id, category: "nope" }
      expect(response.status).to eq(422)
    end

    it "prevents reporting your own post" do
      sign_in(admin)
      own = Fabricate(:post, user: admin)
      post "/school/report.json", params: { post_id: own.id, category: "spam" }
      expect(response.status).to eq(403)
    end
  end

  describe "review queue permissions" do
    it "denies regular users" do
      sign_in(user)
      get "/school/review.json"
      expect(response.status).to eq(403)
    end

    it "allows staff" do
      sign_in(moderator)
      get "/school/review.json"
      expect(response.status).to eq(200)
    end
  end

  describe "POST /school/review-act.json" do
    before do
      SchoolEngine::Moderation.record_report!(
        post, reporter: user, category: "spam", reason: "test", anonymous: false,
      )
    end

    it "folds and restores" do
      sign_in(admin)
      post "/school/review-act.json", params: { post_id: post.id, action_code: "fold", note: "测试折叠" }
      expect(response.status).to eq(200)
      expect(post.reload.custom_fields["mod_state"]).to eq("folded")

      post "/school/review-act.json", params: { post_id: post.id, action_code: "restore", note: "恢复" }
      expect(post.reload.custom_fields["mod_state"]).to eq("normal")
    end

    it "notifies the reporter" do
      sign_in(admin)
      expect { post "/school/review-act.json", params: { post_id: post.id, action_code: "remove", note: "违规" } }.to change { Topic.where(archetype: "private_message").count }.by(1)
      expect(post.reload.custom_fields["mod_state"]).to eq("removed")
    end
  end

  describe "appeals" do
    it "lets the author appeal an action and staff uphold it" do
      sign_in(user)
      SchoolEngine::Moderation.apply_action!(post, state: "pending", action: "hide_pending", actor: admin, note: "x", minutes: 60)
      post "/school/appeal.json", params: { post_id: post.id, body: "我没有违规，请复核" }
      expect(response.status).to eq(200)
      expect(user.reload.custom_fields["appeal_state"]).to eq("pending")

      sign_in(admin)
      post "/school/resolve-appeal.json", params: { user_id: user.id, result: "uphold", note: "误判" }
      expect(response.status).to eq(200)
      expect(post.reload.custom_fields["mod_state"]).to eq("normal")
      expect(user.reload.custom_fields["appeal_state"]).to eq("uphold")
    end
  end

  describe "AI review" do
    it "never blocks post creation and flags risky text" do
      result = SchoolEngine::AiReview.evaluate(Post.new(raw: "我想自杀"))
      expect(result[:cats]).to include("self_harm")
      expect(result[:severity]).to eq("high")
      expect(result[:action]).to eq("escalate")
    end

    it "detects contact leaks" do
      result = SchoolEngine::AiReview.evaluate(Post.new(raw: "有事打13812345678"))
      expect(result[:cats]).to include("contact_leak")
    end
  end

  describe "moderation log" do
    it "keeps an auditable event trail" do
      sign_in(admin)
      SchoolEngine::Moderation.record_report!(post, reporter: user, category: "spam", reason: "x", anonymous: false)
      SchoolEngine::Moderation.fold!(post, actor: admin, note: "折叠")
      kinds = SchoolEngine::Moderation.events(post).map { |e| e["kind"] }
      expect(kinds).to include("reported", "action")
    end
  end
end
