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
import DExpandingTextArea from "discourse/ui-kit/d-expanding-text-area";
import DToggleSwitch from "discourse/ui-kit/d-toggle-switch";
import { i18n } from "discourse-i18n";

/**
 * 固定一键举报弹窗：分类必选 + 可选说明 + 可选匿名（后台仍留痕）。
 */
export default class SchoolReportModal extends Component {
  static cachedCategories = null;

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
    // 举报分类是静态配置，进程内缓存一次即可，避免每次打开弹窗都请求
    if (SchoolReportModal.cachedCategories) {
      this.categories = SchoolReportModal.cachedCategories;
      return;
    }
    ajax("/school/report-categories.json")
      .then((res) => {
        this.categories = res.categories || [];
        SchoolReportModal.cachedCategories = this.categories;
      })
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
                  aria-pressed={{eq this.selected c.code}}
                  {{on "click" (fn this.choose c.code)}}
                >
                  <span class="school-report-cat-label">{{c.label}}</span>
                  {{#if c.hint}}<span class="school-report-cat-hint">{{c.hint}}</span>{{/if}}
                  {{#if (eq this.selected c.code)}}
                    <span class="school-report-cat-check" aria-hidden="true">✓</span>
                  {{/if}}
                </button>
              </li>
            {{/each}}
          </ul>
          <label class="school-report-reason">
            <span>{{i18n "school_engine.report.reason_label"}}</span>
            <DExpandingTextArea
              rows="3"
              @maxlength="500"
              @value={{this.reason}}
              placeholder={{i18n "school_engine.report.reason_placeholder"}}
              {{on "input" this.updateReason}}
            />
          </label>
          <div class="school-report-anon">
            <DToggleSwitch
              @state={{this.anonymous}}
              @label={{i18n "school_engine.report.anonymous_label"}}
              {{on "click" this.toggleAnonymous}}
            />
          </div>
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
            @title={{if this.selected this.selectedCategory.label (i18n "school_engine.report.pick_type")}}
            @isLoading={{this.submitting}}
          />
          <DButton @translatedLabel={{i18n "school_engine.report.cancel"}} @action={{@closeModal}} />
        {{/if}}
      </:footer>
    </DModal>
  </template>
}
