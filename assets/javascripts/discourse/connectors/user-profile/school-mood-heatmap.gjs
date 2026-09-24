import Component from "@glimmer/component";
import SchoolMoodHeatmap from "../../components/school-mood-heatmap";

/**
 * 个人主页注入「心情记录」热力图（user-profile outlet）。
 * outlet model 为 UserProfile 模型（其 .user 为用户对象），兼容直接传 user。
 */
export default class SchoolMoodHeatmapConnector extends Component {
  get user() {
    const model = this.args.outletArgs?.model;
    return model?.user || model;
  }

  <template>
    <SchoolMoodHeatmap @user={{this.user}} />
  </template>
}
