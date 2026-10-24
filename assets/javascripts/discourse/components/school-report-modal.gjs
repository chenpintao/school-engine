import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { not } from "discourse/truth-helpers";
import { eq } from "discourse/truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";

/**
 * 固定一键举报弹窗：分类必选 + 可选说明 + 可选匿名（后台仍留痕）。
 */
export default class SchoolReportModal extends Component {
  @service currentUser;

  @tracked categories = [];
  @tracked selected = null;
  @tracked reason = "";
  @tracked anonymous = false;
  @tracked submitting = false;
  @tracked done = false;
  @tracked message = "";

  constructor() {
    super(...arguments);
    ajax("/school/report-categories.json")
      .then((res) => (this.categories = res.categories || []))
      .catch(popupAjaxError);
  }

  get selectedCategory() {
    return this.categories.find((c) => c.code === this.selected);
  }

  @action
  choose(code) {
    this.selected = code;
  }

  @action
  updateReason(event) {
    this.reason = event.target.value;
  }

  @action
  toggleAnonymous() {
    this.anonymous = !this.anonymous;
  }

  @action
  submit() {
    if (!this.selected || this.submitting) {
      return;
    }
    this.submitting = true;
    ajax("/school/report.json", {
      type: "POST",
      data: {
        post_id: this.args.model.postId,
        category: this.selected,
        reason: this.reason.trim(),
        anonymous: this.anonymous,
      },
    })
      .then((res) => {
        this.submitting = false;
        this.done = true;
        this.message = res.message;
      })
      .catch((e) => {
        this.submitting = false;
        popupAjaxError(e);
      });
  }

  <template>
    <DModal
      @closeModal={{@closeModal}}
      @title={{i18n "school_engine.report.modal_title"}}
      class="school-report-modal"
    >
      <:body>
        {{#if this.done}}
          <p class="school-report-thanks">{{this.message}}</p>
        {{else}}
          <p class="school-report-intro">{{i18n "school_engine.report.modal_intro"}}</p>
          <ul class="school-report-cats">
            {{#each this.categories as |c|}}
              <li>
                <button
                  type="button"
                  class="school-report-cat {{if (eq this.selected c.code) 'is-selected'}}"
                  {{on "click" (fn this.choose c.code)}}
                >
                  <span class="school-report-cat-label">{{c.label}}</span>
                  {{#if c.hint}}<span class="school-report-cat-hint">{{c.hint}}</span>{{/if}}
                </button>
              </li>
            {{/each}}
          </ul>
          <label class="school-report-reason">
            <span>{{i18n "school_engine.report.reason_label"}}</span>
            <textarea
              rows="3"
              maxlength="500"
              placeholder={{i18n "school_engine.report.reason_placeholder"}}
              {{on "input" this.updateReason}}
            ></textarea>
          </label>
          <label class="school-report-anon">
            <input type="checkbox" checked={{this.anonymous}} {{on "change" this.toggleAnonymous}} />
            <span>{{i18n "school_engine.report.anonymous_label"}}</span>
          </label>
          <p class="school-report-privacy">{{i18n "school_engine.report.privacy_note"}}</p>
        {{/if}}
      </:body>
      <:footer>
        {{#if this.done}}
          <DButton @translatedLabel={{i18n "school_engine.report.close"}} @action={{@closeModal}} />
        {{else}}
          <DButton
            @translatedLabel={{i18n "school_engine.report.submit"}}
            @type="primary"
            @action={{this.submit}}
            @disabled={{not this.selected}}
            @isLoading={{this.submitting}}
          />
          <DButton @translatedLabel={{i18n "school_engine.report.cancel"}} @action={{@closeModal}} />
        {{/if}}
      </:footer>
    </DModal>
  </template>
}
