import Component from "@glimmer/component";
import { action } from "@ember/object";
import { fn } from "@ember/helper";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";

/**
 * 小升初选班模态框：diff==3 且未选初中班时弹出。
 *  - 选班：写入 junior_class 并加入初中圈
 *  - 我已离校：小学毕业考去外校初中 → 标记离校并加入毕业生组
 */
export default class SchoolJuniorClassModal extends Component {
  get classes() {
    return this.args.model?.classes || [];
  }

  @action
  selectClass(name) {
    ajax("/school/select-junior-class.json", {
      type: "POST",
      data: { class_name: name },
    })
      .then(() => {
        window.location.reload();
      })
      .catch(popupAjaxError);
  }

  @action
  leaveSchool() {
    ajax("/school/leave-school.json", { type: "POST" })
      .then(() => {
        window.location.reload();
      })
      .catch(popupAjaxError);
  }

  <template>
    <DModal
      @closeModal={{@closeModal}}
      @title={{i18n "school_engine.junior_class_title"}}
      class="school-junior-class-modal"
    >
      <:body>
        <p>{{i18n "school_engine.junior_class_prompt"}}</p>
        <div class="school-class-grid">
          {{#each this.classes as |c|}}
            <DButton
              @translatedLabel={{c}}
              @type="primary"
              @action={{fn this.selectClass c}}
              class="school-class-btn"
            />
          {{/each}}
        </div>
        <div class="school-leave-row">
          <DButton
            @translatedLabel={{i18n "school_engine.leave_school_button"}}
            @action={{this.leaveSchool}}
            class="school-leave-btn btn-default"
          />
          <span class="school-leave-hint">{{i18n "school_engine.leave_school_hint"}}</span>
        </div>
      </:body>
    </DModal>
  </template>
}
