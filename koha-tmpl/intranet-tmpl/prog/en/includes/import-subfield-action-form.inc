<li>
  <select name="action_type">
    <option value="delete">Remove:</option>
    <option value="add_always">Add:</option>
    <option value="add">Add, if not present:</option>
  </select>
  tag <input type="text" name="action_tag" value="" size="3" maxlength="3" />
  subfield <input type="text" name="action_subfield" value="" size="1" maxlength="1" />
  <span class="action-contents-text" style="display: none"> with contents <input type="text" name="action_contents" value="" size="20" /></span>
  <input type="button" class="remove-action" value="-" />
  <input type="button" class="new-action" value="+" />
</li>
