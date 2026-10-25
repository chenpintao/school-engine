import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { eq, not } from "discourse/truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import DEmptyState from "discourse/ui-kit/d-empty-state";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import DExpandingTextArea from "discourse/ui-kit/d-expanding-text-area";
import { i18n } from "discourse-i18n";

/**
 * 审核复核台（/school/review，staff 与复核组共用）。
 *
 * 深度复用 Discourse 官方组件，保持与核心一致的视觉与交互：
 *  - d-stat-tiles 官方样式类（看板统计）
 *  - DEmptyState  空状态
 *  - DConditionalLoadingSpinner  加载态
 *  - DButton / DModal / DExpandingTextArea / DTooltip
 *
 * 一次请求只拉队列，看板与申诉按需加载，减少首屏等待。
 */
export default class SchoolReviewPanel extends Component {
  @service currentUser;

  @tracked loading = true;
  @tracked allowed = false;
  @tracked items = [];
  @tracked total = 0;
  @tracked filter = "all";
  @tracked board = null;
  @tracked appeals = [];
  @tracked openDetail = null;
  @tracked note = "";
  @tracked busy = false;

  constructor() {
    super(...arguments);
    this.init();
  }

  @action
  init() {
    this.loading = true;
    ajax("/school/review.json", { data: { filter: this.filter, limit: 30 } })
      .then((res) => {
        this.allowed = true;
        this.items = res.items || [];
        this.total = res.total || 0;
        this.loading = false;
        // 看板与申诉延后加载，不阻塞队列首屏
        this.loadBoard();
        this.loadAppeals();
      })
      .catch(() => {
        this.allowed = false;
        this.loading = false;
      });
  }

  @action
  loadBoard() {
    ajax("/school/review-board.json", { data: { days: 30 } })
      .then((res) => (this.board = res))
      .catch(() => null);
  }

  @action
  loadAppeals() {
    ajax("/school/appeals.json")
      .then((res) => (this.appeals = res.appeals || []))
      .catch(() => (this.appeals = []));
  }

  @action
  refresh() {
    this.init();
  }

  @action
  setFilter(value) {
    if (this.filter === value) {
      return;
    }
    this.filter = value;
    this.init();
  }

  @action
  open(item) {
    this.openDetail = item;
    this.note = "";
  }

  @action
  close() {
    this.openDetail = null;
    this.note = "";
  }

  @action
  updateNote(event) {
    this.note = event.target.value;
  }

  @action
  act(actionCode) {
    if (!this.openDetail || this.busy) {
      return;
    }
    this.busy = true;
    ajax("/school/review-act.json", {
      type: "POST",
      data: {
        post_id: this.openDetail.post_id,
        action_code: actionCode,
        note: this.note.trim(),
      },
    })
      .then(() => {
        this.busy = false;
        this.close();
        this.init();
      })
      .catch((e) => {
        this.busy = false;
        popupAjaxError(e);
      });
  }

  @action
  resolveAppeal(userId, result) {
    ajax("/school/resolve-appeal.json", {
      type: "POST",
      data: { user_id: userId, result, note: this.note.trim() },
    })
      .then(() => {
        this.loadAppeals();
        this.init();
      })
      .catch(popupAjaxError);
  }

  get exportUrl() {
    return "/school/review-export.csv";
  }

  get isEmpty() {
    return !this.loading && this.allowed && this.items.length === 0;
  }

  get stateLabel() {
    const map = {
      pending: i18n("school_engine.review.state_pending"),
      escalated: i18n("school_engine.review.state_escalated"),
      folded: i18n("school_engine.review.state_folded"),
      hidden: i18n("school_engine.review.state_hidden"),
      removed: i18n("school_engine.review.state_removed"),
      normal: i18n("school_engine.review.state_normal"),
    };
    return (state) => map[state] || state;
  }

  <template>
    <div class="school-review">
      {{#if this.loading}}
        <DConditionalLoadingSpinner @condition={{true}} />
      {{else if this.allowed}}
        <header class="school-review-header">
          <h1>{{i18n "school_engine.review.title"}}</h1>
          <p class="school-review-subtitle">{{i18n "school_engine.review.subtitle"}}</p>
        </header>

        {{#if this.board}}
          <div class="d-stat-tiles --grid-3 school-review-board">
            <div class="d-stat-tile" role="group">
              <div class="d-stat-tile__top">
                <span class="d-stat-tile__label">{{i18n "school_engine.review.stat_pending"}}</span>
              </div>
              <span class="d-stat-tile__value">{{this.board.states.pending}}</span>
            </div>
            <div class="d-stat-tile" role="group">
              <div class="d-stat-tile__top">
                <span class="d-stat-tile__label">{{i18n "school_engine.review.stat_escalated"}}</span>
              </div>
              <span class="d-stat-tile__value">{{this.board.states.escalated}}</span>
            </div>
            <div class="d-stat-tile" role="group">
              <div class="d-stat-tile__top">
                <span class="d-stat-tile__label">{{i18n "school_engine.review.stat_folded"}}</span>
              </div>
              <span class="d-stat-tile__value">{{this.board.states.folded}}</span>
            </div>
            <div class="d-stat-tile" role="group">
              <div class="d-stat-tile__top">
                <span class="d-stat-tile__label">{{i18n "school_engine.review.stat_overdue"}}</span>
              </div>
              <span class="d-stat-tile__value">{{this.board.overdue}}</span>
            </div>
            <div class="d-stat-tile" role="group">
              <div class="d-stat-tile__top">
                <span class="d-stat-tile__label">{{i18n "school_engine.review.stat_ai"}}</span>
              </div>
              <span class="d-stat-tile__value">{{this.board.ai_flagged}}</span>
            </div>
          </div>
        {{/if}}

        <section class="school-review-toolbar">
          <DButton
            @translatedLabel={{i18n "school_engine.review.filter_all"}}
            @action={{fn this.setFilter "all"}}
            class="btn-default {{if (eq this.filter 'all') 'is-active'}}"
          />
          <DButton
            @translatedLabel={{i18n "school_engine.review.filter_overdue"}}
            @action={{fn this.setFilter "overdue"}}
            class="btn-default {{if (eq this.filter 'overdue') 'is-active'}}"
          />
          <span class="school-review-total">
            {{i18n "school_engine.review.total_count" count=this.total}}
          </span>
          <DButton
            @translatedLabel={{i18n "school_engine.review.refresh"}}
            @action={{this.refresh}}
            @icon="arrows-rotate"
            class="btn-default"
          />
          <a class="school-review-export" href={{this.exportUrl}}>
            {{i18n "school_engine.review.export"}}
          </a>
        </section>

        {{#if this.isEmpty}}
          <DEmptyState @title={{i18n "school_engine.review.empty"}} />
        {{else}}
          <ul class="school-review-list">
            {{#each this.items as |item|}}
              <li class="school-review-item {{if item.overdue 'is-overdue'}}">
                <div class="school-review-item-head">
                  <span class="school-review-state state-{{item.state}}">
                    {{this.stateLabel item.state}}
                  </span>
                  {{#each item.categories as |c|}}
                    <span class="school-review-tag">{{c.label}}</span>
                  {{/each}}
                  {{#if item.overdue}}
                    <span class="school-review-overdue">
                      {{i18n "school_engine.review.overdue"}}
                    </span>
                  {{/if}}
                  {{#if item.conflict}}
                    <span class="school-review-conflict">
                      {{i18n "school_engine.review.conflict"}}
                    </span>
                  {{/if}}
                </div>

                <div class="school-review-item-body">
                  <div class="school-review-item-title">{{item.topic_title}}</div>
                  <div class="school-review-item-author">
                    {{item.author}} · {{item.author_class}} · #{{item.post_number}}
                  </div>
                  <p class="school-review-item-excerpt">{{item.excerpt}}</p>
                  <div class="school-review-item-meta">
                    <span>{{i18n "school_engine.review.report_count" count=item.report_count}}</span>
                    <span>AI {{item.ai.action}} ({{item.ai.score}})</span>
                    <span>{{i18n "school_engine.review.deadline"}} {{item.deadline}}</span>
                  </div>
                </div>

                <div class="school-review-item-actions">
                  <DButton
                    @translatedLabel={{i18n "school_engine.review.open"}}
                    @action={{fn this.open item}}
                    class="btn-primary"
                  />
                  <a href={{item.url}} target="_blank" rel="noopener noreferrer">
                    {{i18n "school_engine.review.view_post"}}
                  </a>
                </div>
              </li>
            {{/each}}
          </ul>
        {{/if}}

        <section class="school-review-appeals">
          <h2>{{i18n "school_engine.review.appeals_title"}}</h2>
          {{#if this.appeals.length}}
            <ul>
              {{#each this.appeals as |a|}}
                <li class="school-review-appeal">
                  <div>
                    <strong>{{a.username}}</strong>
                    <span class="school-review-tag">#{{a.post_id}}</span>
                    <p>{{a.body}}</p>
                  </div>
                  <div class="school-review-appeal-actions">
                    <DButton
                      @translatedLabel={{i18n "school_engine.review.appeal_uphold"}}
                      @action={{fn this.resolveAppeal a.user_id "uphold"}}
                      class="btn-primary"
                    />
                    <DButton
                      @translatedLabel={{i18n "school_engine.review.appeal_reject"}}
                      @action={{fn this.resolveAppeal a.user_id "reject"}}
                      class="btn-default"
                    />
                  </div>
                </li>
              {{/each}}
            </ul>
          {{else}}
            <p class="school-review-empty-line">{{i18n "school_engine.review.no_appeals"}}</p>
          {{/if}}
        </section>

        {{#if this.openDetail}}
          <DModal
            @closeModal={{this.close}}
            @title={{i18n "school_engine.review.detail_title"}}
            class="school-review-drawer"
          >
            <:body>
              <h3 class="school-review-detail-title">
                {{this.openDetail.topic_title}} · #{{this.openDetail.post_number}}
              </h3>
              <p class="school-review-drawer-raw">{{this.openDetail.raw}}</p>

              <label class="school-review-note">
                <span>{{i18n "school_engine.review.note"}}</span>
                <DExpandingTextArea
                  rows="2"
                  @value={{this.note}}
                  placeholder={{i18n "school_engine.review.note_placeholder"}}
                  {{on "input" this.updateNote}}
                />
              </label>

              <ol class="school-review-log">
                {{#each this.openDetail.events as |e|}}
                  <li>
                    <code>{{e.at}}</code>
                    <strong>{{e.kind}}</strong>
                    {{e.note}}
                  </li>
                {{/each}}
              </ol>
            </:body>
            <:footer>
              <div class="school-review-drawer-actions">
                <DButton
                  @translatedLabel={{i18n "school_engine.review.act_hint"}}
                  @action={{fn this.act "hint"}}
                  class="btn-default"
                  @isLoading={{this.busy}}
                />
                <DButton
                  @translatedLabel={{i18n "school_engine.review.act_fold"}}
                  @action={{fn this.act "fold"}}
                  class="btn-default"
                  @isLoading={{this.busy}}
                />
                <DButton
                  @translatedLabel={{i18n "school_engine.review.act_pending"}}
                  @action={{fn this.act "hide_pending"}}
                  class="btn-default"
                  @isLoading={{this.busy}}
                />
                <DButton
                  @translatedLabel={{i18n "school_engine.review.act_timed"}}
                  @action={{fn this.act "hide_timed"}}
                  class="btn-default"
                  @isLoading={{this.busy}}
                />
                <DButton
                  @translatedLabel={{i18n "school_engine.review.act_remove"}}
                  @action={{fn this.act "remove"}}
                  class="btn-danger"
                  @isLoading={{this.busy}}
                />
                <DButton
                  @translatedLabel={{i18n "school_engine.review.act_escalate"}}
                  @action={{fn this.act "escalate"}}
                  class="btn-default"
                  @isLoading={{this.busy}}
                />
                <DButton
                  @translatedLabel={{i18n "school_engine.review.act_restore"}}
                  @action={{fn this.act "restore"}}
                  class="btn-primary"
                  @isLoading={{this.busy}}
                />
              </div>
            </:footer>
          </DModal>
        {{/if}}
      {{else}}
        <DEmptyState
          @title={{i18n "school_engine.review.denied"}}
          @body={{i18n "school_engine.review.denied_body"}}
        />
      {{/if}}
    </div>
  </template>
}
