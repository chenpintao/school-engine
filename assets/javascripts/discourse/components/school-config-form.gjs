import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { not, eq } from "discourse/truth-helpers";
import { didInsert } from "@ember/render-modifiers/modifiers/did-insert";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import DToggleSwitch from "discourse/ui-kit/d-toggle-switch";
import { i18n } from "discourse-i18n";

/**
 * 校园插件配置页（/school/config，staff）：
 *  - 分类匿名规则：每个分类 forced（强制：OP+回帖全匿名）/
 *    optional（可选：仅回帖可匿名，精选/胶囊作用于这类分类）/ disabled（禁止）
 *  - 功能开关：精选 / 时光胶囊 / 心情签到 / 固定标签
 *  - 参数：每日精选上限、胶囊点赞阈值、两学期期末月-日
 * GET/PUT /school/config.json，规则留空时服务端使用内置默认（confess/anonymous-wall）。
 */
const DEFAULT_RULES = [
  { slug: "confess", mode: "optional" },
  { slug: "anonymous-wall", mode: "forced" },
];
const MODES = ["forced", "optional", "disabled"];
const FEATURE_KEYS = [
  "school_engine_feature_enabled",
  "school_engine_capsule_enabled",
  "school_engine_mood_enabled",
  "school_engine_tags_enabled",
];

export default class SchoolConfigForm extends Component {
  @service site;
  @tracked loaded = false;
  @tracked loadError = false;
  @tracked saving = false;
  @tracked saved = false;
  @tracked rules = DEFAULT_RULES.map((rule) => ({ ...rule }));
  @tracked features = {};
  @tracked settings = {
    featured_per_day: 3,
    capsule_like_threshold: 10,
    semester_end_1: "1-31",
    semester_end_2: "7-31",
  };

  modes = MODES;
  featureKeys = FEATURE_KEYS;

  get categories() {
    return this.site.categories || [];
  }

  modeLabel(mode) {
    return i18n(`school_engine.config_mode_${mode}`);
  }

  featureLabel(key) {
    return i18n(`school_engine.config_${key}`);
  }

  featureState(key) {
    return this.features[key] === true;
  }

  settingValue(key) {
    return this.settings[key];
  }

  @action
  load() {
    ajax("/school/config.json")
      .then((data) => {
        this.rules = (data.category_rules || []).map((rule) => ({
          slug: rule.slug,
          mode: rule.mode,
        }));
        this.features = data.features || {};
        this.settings = { ...this.settings, ...(data.settings || {}) };
        this.loaded = true;
      })
      .catch((error) => {
        this.loadError = true;
        popupAjaxError(error);
      });
  }

  @action
  addRule() {
    this.saved = false;
    this.rules = [...this.rules, { slug: "", mode: "optional" }];
  }

  @action
  removeRule(index) {
    this.saved = false;
    this.rules = this.rules.filter((_, i) => i !== index);
  }

  @action
  setSlug(index, event) {
    this.saved = false;
    this.rules[index] = { ...this.rules[index], slug: event.target.value };
    this.rules = [...this.rules];
  }

  @action
  setMode(index, event) {
    this.saved = false;
    this.rules[index] = { ...this.rules[index], mode: event.target.value };
    this.rules = [...this.rules];
  }

  @action
  toggleFeature(key) {
    this.saved = false;
    this.features = { ...this.features, [key]: !this.features[key] };
  }

  @action
  setSetting(key, event) {
    this.saved = false;
    this.settings = { ...this.settings, [key]: event.target.value };
  }

  @action
  save() {
    this.saving = true;
    ajax("/school/config.json", {
      type: "PUT",
      data: {
        category_rules: this.rules,
        features: this.features,
        settings: this.settings,
      },
    })
      .then((data) => {
        this.rules = (data.category_rules || []).map((rule) => ({
          slug: rule.slug,
          mode: rule.mode,
        }));
        this.features = data.features || {};
        this.settings = { ...this.settings, ...(data.settings || {}) };
        this.saved = true;
      })
      .catch(popupAjaxError)
      .finally(() => {
        this.saving = false;
      });
  }

  <template>
    <div class="school-config" {{didInsert this.load}}>
      <header class="school-config-header">
        <h1 class="school-config-title">{{i18n "school_engine.config_title"}}</h1>
        <p class="school-config-subtitle">{{i18n "school_engine.config_subtitle"}}</p>
      </header>

      {{#if this.loaded}}
        <section class="school-config-card">
          <div class="school-config-card-head">
            <h2>{{i18n "school_engine.config_rules_title"}}</h2>
            <DButton
              @icon="plus"
              @label="school_engine.config_add_rule"
              @action={{this.addRule}}
              class="btn-default school-config-add"
            />
          </div>
          <p class="school-config-card-desc">{{i18n "school_engine.config_rules_desc"}}</p>

          <ul class="school-config-rules">
            {{#each this.rules as |rule index|}}
              <li class="school-config-rule">
                <div class="school-config-field">
                  <label>{{i18n "school_engine.config_category"}}</label>
                  <select {{on "change" (fn this.setSlug index)}}>
                    <option value="" selected={{not rule.slug}}>
                      {{i18n "school_engine.config_select_category"}}
                    </option>
                    {{#each this.categories as |category|}}
                      <option value={{category.slug}} selected={{eq category.slug rule.slug}}>
                        {{category.name}} · {{category.slug}}
                      </option>
                    {{/each}}
                  </select>
                </div>
                <div class="school-config-field">
                  <label>{{i18n "school_engine.config_anonymity"}}</label>
                  <select {{on "change" (fn this.setMode index)}}>
                    {{#each this.modes as |mode|}}
                      <option value={{mode}} selected={{eq mode rule.mode}}>
                        {{this.modeLabel mode}}
                      </option>
                    {{/each}}
                  </select>
                </div>
                <DButton
                  @icon="trash-can"
                  @action={{fn this.removeRule index}}
                  class="btn-default school-config-remove"
                />
              </li>
            {{/each}}
          </ul>
        </section>

        <section class="school-config-card">
          <div class="school-config-card-head">
            <h2>{{i18n "school_engine.config_features_title"}}</h2>
          </div>
          <ul class="school-config-switches">
            {{#each this.featureKeys as |key|}}
              <li class="school-config-switch">
                <DToggleSwitch
                  @state={{this.featureState key}}
                  @label={{this.featureLabel key}}
                  {{on "click" (fn this.toggleFeature key)}}
                />
              </li>
            {{/each}}
          </ul>
        </section>

        <section class="school-config-card">
          <div class="school-config-card-head">
            <h2>{{i18n "school_engine.config_params_title"}}</h2>
          </div>
          <div class="school-config-params">
            <div class="school-config-field">
              <label>{{i18n "school_engine.config_featured_per_day"}}</label>
              <input
                type="number"
                min="1"
                value={{this.settingValue "featured_per_day"}}
                {{on "input" (fn this.setSetting "featured_per_day")}}
              />
            </div>
            <div class="school-config-field">
              <label>{{i18n "school_engine.config_capsule_like_threshold"}}</label>
              <input
                type="number"
                min="1"
                value={{this.settingValue "capsule_like_threshold"}}
                {{on "input" (fn this.setSetting "capsule_like_threshold")}}
              />
            </div>
            <div class="school-config-field">
              <label>{{i18n "school_engine.config_semester_end_1"}}</label>
              <input
                type="text"
                value={{this.settingValue "semester_end_1"}}
                {{on "input" (fn this.setSetting "semester_end_1")}}
              />
            </div>
            <div class="school-config-field">
              <label>{{i18n "school_engine.config_semester_end_2"}}</label>
              <input
                type="text"
                value={{this.settingValue "semester_end_2"}}
                {{on "input" (fn this.setSetting "semester_end_2")}}
              />
            </div>
          </div>
        </section>

        <div class="school-config-footer">
          {{#if this.saved}}
            <span class="school-config-saved">{{i18n "school_engine.config_saved"}}</span>
          {{/if}}
          <DButton
            @icon="check"
            @label="school_engine.config_save"
            @action={{this.save}}
            @disabled={{this.saving}}
            class="btn-primary"
          />
        </div>
      {{else if this.loadError}}
        <div class="school-config-error">{{i18n "school_engine.config_load_error"}}</div>
      {{/if}}
    </div>
  </template>
}
