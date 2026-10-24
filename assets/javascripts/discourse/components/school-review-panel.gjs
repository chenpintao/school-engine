import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { eq } from "discourse/truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

/**
 * 审核复核台（/school/review，staff 与复核组共用）。
 * 一个页面三块：举报队列（含 AI 标记与 SLA）、举报看板、申诉处理。
 * 版主利益冲突（本班/本人）时后端返回 conflict，前端提供"转交"按钮。
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
      .catch(popupAjaxError);
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

  <template>
    <div class="school-review">
      {{#if this.loading}}
        <p class="school-review-loading">{{i18n "school_engine.review.loading"}}</p>
      {{else if this.allowed}}
        <header class="school-review-header">
          <h1>{{i18n "school_engine.review.title"}}</h1>
          <p class="school-review-subtitle">{{i18n "school_engine.review.subtitle"}}</p>
        </header>

        {{#if this.board}}
          <section class="school-review-board">
            <div class="school-review-stat">
              <span class="num">{{this.board.states.pending}}</span>
              <span class="label">{{i18n "school_engine.review.stat_pending"}}</span>
            </div>
            <div class="school-review-stat">
              <span class="num">{{this.board.states.escalated}}</span>
              <span class="label">{{i18n "school_engine.review.stat_escalated"}}</span>
            </div>
            <div class="school-review-stat">
              <span class="num">{{this.board.states.folded}}</span>
              <span class="label">{{i18n "school_engine.review.stat_folded"}}</span>
            </div>
            <div class="school-review-stat is-warn">
              <span class="num">{{this.board.overdue}}</span>
              <span class="label">{{i18n "school_engine.review.stat_overdue"}}</span>
            </div>
            <div class="school-review-stat">
              <span class="num">{{this.board.ai_flagged}}</span>
              <span class="label">{{i18n "school_engine.review.stat_ai"}}</span>
            </div>
            <a class="school-review-export" href={{this.exportUrl}}>{{i18n "school_engine.review.export"}}</a>
          </section>
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
          <span class="school-review-total">共 {{this.total}} 条</span>
          <DButton @translatedLabel={{i18n "school_engine.review.refresh"}} @action={{this.refresh}} class="btn-default" />
        </section>

        <ul class="school-review-list">
          {{#each this.items as |item|}}
            <li class="school-review-item {{if item.overdue 'is-overdue'}}">
              <div class="school-review-item-head">
                <span class="school-review-state state-{{item.state}}">{{item.state}}</span>
                {{#each item.categories as |c|}}
                  <span class="school-review-tag">{{c.label}}</span>
                {{/each}}
                {{#if item.overdue}}<span class="school-review-overdue">{{i18n "school_engine.review.overdue"}}</span>{{/if}}
                {{#if item.conflict}}<span class="school-review-conflict">{{i18n "school_engine.review.conflict"}}</span>{{/if}}
              </div>
              <div class="school-review-item-body">
                <div class="school-review-item-title">{{item.topic_title}}</div>
                <div class="school-review-item-author">
                  {{item.author}} · {{item.author_class}} · #{{item.post_number}}
                </div>
                <p class="school-review-item-excerpt">{{item.excerpt}}</p>
                <div class="school-review-item-meta">
                  <span>举报 {{item.report_count}} 次</span>
                  <span>AI {{item.ai.action}} ({{item.ai.score}})</span>
                  <span>{{i18n "school_engine.review.deadline"}} {{item.deadline}}</span>
                </div>
              </div>
              <div class="school-review-item-actions">
                <DButton @translatedLabel={{i18n "school_engine.review.open"}} @action={{fn this.open item}} class="btn-primary" />
                <a href={{item.url}} target="_blank" rel="noopener noreferrer">查看原帖</a>
              </div>
            </li>
          {{else}}
            <li class="school-review-empty">{{i18n "school_engine.review.empty"}}</li>
          {{/each}}
        </ul>

        <section class="school-review-appeals">
          <h2>{{i18n "school_engine.review.appeals_title"}}</h2>
          <ul>
            {{#each this.appeals as |a|}}
              <li class="school-review-appeal">
                <div>
                  <strong>{{a.username}}</strong>
                  <span class="school-review-tag">#{{a.post_id}}</span>
                  <p>{{a.body}}</p>
                </div>
                <div class="school-review-appeal-actions">
                  <DButton @translatedLabel={{i18n "school_engine.review.appeal_uphold"}} @action={{fn this.resolveAppeal a.user_id "uphold"}} class="btn-primary" />
                  <DButton @translatedLabel={{i18n "school_engine.review.appeal_reject"}} @action={{fn this.resolveAppeal a.user_id "reject"}} class="btn-default" />
                </div>
              </li>
            {{else}}
              <li class="school-review-empty">{{i18n "school_engine.review.no_appeals"}}</li>
            {{/each}}
          </ul>
        </section>

        {{#if this.openDetail}}
          <div class="school-review-drawer">
            <div class="school-review-drawer-head">
              <h2>{{this.openDetail.topic_title}} · #{{this.openDetail.post_number}}</h2>
              <DButton @translatedLabel={{i18n "school_engine.review.close"}} @action={{this.close}} class="btn-default" />
            </div>
            <p class="school-review-drawer-raw">{{this.openDetail.raw}}</p>
            <label class="school-review-note">
              <span>{{i18n "school_engine.review.note"}}</span>
              <textarea rows="2" {{on "input" this.updateNote}} placeholder={{i18n "school_engine.review.note_placeholder"}}></textarea>
            </label>
            <div class="school-review-drawer-actions">
              <DButton @translatedLabel={{i18n "school_engine.review.act_hint"}} @action={{fn this.act "hint"}} class="btn-default" @isLoading={{this.busy}} />
              <DButton @translatedLabel={{i18n "school_engine.review.act_fold"}} @action={{fn this.act "fold"}} class="btn-default" @isLoading={{this.busy}} />
              <DButton @translatedLabel={{i18n "school_engine.review.act_pending"}} @action={{fn this.act "hide_pending"}} class="btn-default" @isLoading={{this.busy}} />
              <DButton @translatedLabel={{i18n "school_engine.review.act_timed"}} @action={{fn this.act "hide_timed"}} class="btn-default" @isLoading={{this.busy}} />
              <DButton @translatedLabel={{i18n "school_engine.review.act_remove"}} @action={{fn this.act "remove"}} class="btn-danger" @isLoading={{this.busy}} />
              <DButton @translatedLabel={{i18n "school_engine.review.act_escalate"}} @action={{fn this.act "escalate"}} class="btn-default" @isLoading={{this.busy}} />
              <DButton @translatedLabel={{i18n "school_engine.review.act_restore"}} @action={{fn this.act "restore"}} class="btn-primary" @isLoading={{this.busy}} />
            </div>
            <ol class="school-review-log">
              {{#each this.openDetail.events as |e|}}
                <li><code>{{e.at}}</code> <strong>{{e.kind}}</strong> {{e.note}}</li>
              {{/each}}
            </ol>
          </div>
        {{/if}}
      {{else}}
        <p class="school-review-denied">{{i18n "school_engine.review.denied"}}</p>
      {{/if}}
    </div>
  </template>
}
